#include "webview.h"

#include <WebView2EnvironmentOptions.h>

#include <atomic>
#include <memory>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace winine
{
namespace
{
// Pump this thread's messages until DONE says the async operation finished:
// WebView2 completes its operations by posting to the creating thread, which
// is the Lisp thread here (ewv's wait_for_async_operation does the same).
template <class Done>
void pump_until(Done done)
{
	MSG msg;
	while (!done())
	{
		while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE))
		{
			if (msg.message == WM_QUIT)
			{
				PostQuitMessage(static_cast<int>(msg.wParam));
				return;
			}
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
			if (done())
			{
				return;
			}
		}
		MsgWaitForMultipleObjectsEx(0, nullptr, 50, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
	}
}

int64_t new_webview_id()
{
	static std::atomic<int64_t> next{1};
	return next++;
}

HWND parent_of(ICoreWebView2Controller *controller)
{
	HWND hwnd = nullptr;
	controller->get_ParentWindow(&hwnd);
	return hwnd;
}

// A Lisp callback shared by every event of one handler, kept alive with it
// (like ewv's Rc<GlobalRef>, never freed: handlers live as long as the view).
using SharedCallback = std::shared_ptr<GlobalRef>;

SharedCallback share(Lisp &lisp, emacs_value callback)
{
	return std::make_shared<GlobalRef>(lisp, callback);
}

// INPUT records for a modifier + key chord (ewv's send_keycomb).
void send_chord(WORD modifier, WORD key)
{
	INPUT inputs[4]{};
	WORD  keys[4]  = {modifier, key, key, modifier};
	bool  up[4]    = {false, false, true, true};
	for (int i = 0; i < 4; ++i)
	{
		inputs[i].type       = INPUT_KEYBOARD;
		inputs[i].ki.wVk     = keys[i];
		inputs[i].ki.dwFlags = up[i] ? KEYEVENTF_KEYUP : 0;
	}
	SendInput(4, inputs, sizeof(INPUT));
}

std::string json_escape(const std::string &text)
{
	std::string out = "\"";
	for (unsigned char c : text)
	{
		switch (c)
		{
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if (c < 0x20)
				{
					char buffer[8];
					std::snprintf(buffer, sizeof buffer, "\\u%04x", c);
					out += buffer;
				}
				else
				{
					out += static_cast<char>(c);
				}
		}
	}
	return out + "\"";
}

// ---------------------------------------------------------------------------
// The `bridge' host object: window.chrome.webview.hostObjects.bridge in pages
// (modeline.html). bridge.say_hello(SEXP, CALLBACK) evaluates SEXP in Emacs
// with winine-core--eval-string and calls CALLBACK with the result string.
// ---------------------------------------------------------------------------

class Bridge : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IDispatch>
{
  public:
	explicit Bridge(HWND frame) :
	    frame(frame)
	{}

	HRESULT STDMETHODCALLTYPE GetTypeInfoCount(UINT *count) override
	{
		*count = 0;
		return S_OK;
	}
	HRESULT STDMETHODCALLTYPE GetTypeInfo(UINT, LCID, ITypeInfo **) override
	{
		return E_NOTIMPL;
	}
	HRESULT STDMETHODCALLTYPE GetIDsOfNames(REFIID, LPOLESTR *names, UINT count, LCID, DISPID *ids) override
	{
		HRESULT hr = S_OK;
		for (UINT i = 0; i < count; ++i)
		{
			if (wcscmp(names[i], L"say_hello") == 0)
			{
				ids[i] = 1;
			}
			else
			{
				ids[i] = DISPID_UNKNOWN;
				hr     = DISP_E_UNKNOWNNAME;
			}
		}
		return hr;
	}
	HRESULT STDMETHODCALLTYPE Invoke(DISPID member, REFIID, LCID lcid, WORD flags, DISPPARAMS *params,
	                                 VARIANT *, EXCEPINFO *, UINT *) override
	{
		if (!(flags & DISPATCH_METHOD) || member != 1)
		{
			return DISP_E_MEMBERNOTFOUND;
		}
		if (!params || params->cArgs != 2)
		{
			return DISP_E_BADPARAMCOUNT;
		}
		// Arguments arrive last first.
		VARIANT &name = params->rgvarg[1];
		VARIANT &cb   = params->rgvarg[0];
		if (name.vt != VT_BSTR || cb.vt != VT_DISPATCH || !cb.pdispVal)
		{
			return DISP_E_TYPEMISMATCH;
		}
		std::string         sexp = narrow(name.bstrVal ? name.bstrVal : L"");
		ComPtr<IDispatch>   callback(cb.pdispVal);
		queue_event([sexp, callback, lcid](Lisp &lisp) {
			std::string result = "error";
			try
			{
				result = lisp.to_string(lisp.call("winine-core--eval-string", {lisp.string(sexp)}));
			}
			catch (const LispExit &)
			{
				lisp.env->non_local_exit_clear(lisp.env);
			}
			VARIANT arg;
			VariantInit(&arg);
			arg.vt          = VT_BSTR;
			arg.bstrVal     = SysAllocString(widen(result).c_str());
			DISPPARAMS call = {&arg, nullptr, 1, 0};
			VARIANT    out;
			VariantInit(&out);
			callback->Invoke(DISPID_VALUE, IID_NULL, lcid, DISPATCH_METHOD, &call, &out, nullptr, nullptr);
			VariantClear(&out);
			VariantClear(&arg);
		});
		notify_emacs(frame);
		return S_OK;
	}

  private:
	HWND frame;
};

emacs_value window_features_to_lisp(Lisp &lisp, ICoreWebView2WindowFeatures *features)
{
	BOOL position = FALSE, size = FALSE, menu = FALSE, status = FALSE, toolbar = FALSE, scroll = FALSE;
	features->get_HasPosition(&position);
	features->get_HasSize(&size);
	features->get_ShouldDisplayMenuBar(&menu);
	features->get_ShouldDisplayStatus(&status);
	features->get_ShouldDisplayToolbar(&toolbar);
	features->get_ShouldDisplayScrollBars(&scroll);
	return lisp.list({lisp.intern(":has-position"), lisp.boolean(position),
	                  lisp.intern(":has-size"), lisp.boolean(size),
	                  lisp.intern(":should-display-menu-bar"), lisp.boolean(menu),
	                  lisp.intern(":should-display-status"), lisp.boolean(status),
	                  lisp.intern(":should-display-scroll-bars"), lisp.boolean(scroll)});
}
}        // namespace

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

Environment *Environment::create(const std::optional<std::string> &browser_executable_folder,
                                 const std::optional<std::string> &user_data_folder,
                                 bool                              are_browser_extensions_enabled)
{
	// The Lisp thread is an STA (module init); harmless if already one.
	CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

	auto options = Make<CoreWebView2EnvironmentOptions>();
	ComPtr<ICoreWebView2EnvironmentOptions6> options6;
	if (SUCCEEDED(options.As(&options6)))
	{
		options6->put_AreBrowserExtensionsEnabled(are_browser_extensions_enabled ? TRUE : FALSE);
	}

	std::wstring exe  = browser_executable_folder ? widen(*browser_executable_folder) : L"";
	std::wstring data = user_data_folder ? widen(*user_data_folder) : L"";

	bool                             done   = false;
	HRESULT                          result = S_OK;
	ComPtr<ICoreWebView2Environment> created;
	check(CreateCoreWebView2EnvironmentWithOptions(
	          browser_executable_folder ? exe.c_str() : nullptr, user_data_folder ? data.c_str() : nullptr,
	          options.Get(),
	          Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
	              [&](HRESULT hr, ICoreWebView2Environment *environment) -> HRESULT {
		              result  = hr;
		              created = environment;
		              done    = true;
		              return S_OK;
	              })
	              .Get()),
	      "CreateCoreWebView2EnvironmentWithOptions");
	pump_until([&] { return done; });
	check(result, "creating the WebView2 environment");
	if (!created)
	{
		throw std::runtime_error("WebView2 returned no environment");
	}
	return new Environment{created};
}

// ---------------------------------------------------------------------------
// Webview
// ---------------------------------------------------------------------------

Webview::Webview(HWND parent, Environment &environment) :
    id_(new_webview_id()), parent_(parent)
{
	ComPtr<ICoreWebView2Environment10> env10;
	check(environment.raw.As(&env10), "ICoreWebView2Environment10");
	LPWSTR version = nullptr;
	if (SUCCEEDED(env10->get_BrowserVersionString(&version)))
	{
		log("webview2 version = %s", take(version).c_str());
	}
	ComPtr<ICoreWebView2ControllerOptions> options;
	check(env10->CreateCoreWebView2ControllerOptions(&options), "CreateCoreWebView2ControllerOptions");

	bool    done   = false;
	HRESULT result = S_OK;
	check(env10->CreateCoreWebView2ControllerWithOptions(
	          parent, options.Get(),
	          Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
	              [&](HRESULT hr, ICoreWebView2Controller *controller) -> HRESULT {
		              result      = hr;
		              controller_ = controller;
		              done        = true;
		              return S_OK;
	              })
	              .Get()),
	      "CreateCoreWebView2ControllerWithOptions");
	pump_until([&] { return done; });
	check(result, "creating the WebView2 controller");
	if (!controller_)
	{
		throw std::runtime_error("WebView2 returned no controller");
	}
	check(controller_->get_CoreWebView2(&webview_), "get_CoreWebView2");

	// C-g in a page gives the keyboard back to Emacs; C-x and M-x too, and
	// they are replayed there so the chord still works.
	EventRegistrationToken token;
	controller_->add_AcceleratorKeyPressed(
	    Callback<ICoreWebView2AcceleratorKeyPressedEventHandler>(
	        [](ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *args) -> HRESULT {
		        UINT key = 0;
		        args->get_VirtualKey(&key);
		        COREWEBVIEW2_PHYSICAL_KEY_STATUS status{};
		        args->get_PhysicalKeyStatus(&status);
		        if (key == 'G')
		        {
			        SetFocus(GetActiveWindow());
			        args->put_Handled(TRUE);
		        }
		        else if (key == 'X')
		        {
			        SetFocus(GetActiveWindow());
			        send_chord(status.IsMenuKeyDown ? VK_MENU : VK_CONTROL, 'X');
			        args->put_Handled(TRUE);
		        }
		        else
		        {
			        args->put_Handled(FALSE);
		        }
		        return S_OK;
	        })
	        .Get(),
	    &token);

	auto bridge = Make<Bridge>(parent);
	VARIANT object;
	VariantInit(&object);
	object.vt       = VT_DISPATCH;
	object.pdispVal = bridge.Get();
	object.pdispVal->AddRef();
	check(webview_->AddHostObjectToScript(L"bridge", &object), "AddHostObjectToScript");
	VariantClear(&object);

	ComPtr<ICoreWebView2Settings> settings;
	check(webview_->get_Settings(&settings), "get_Settings");
	settings->put_AreDefaultContextMenusEnabled(TRUE);
	settings->put_AreDevToolsEnabled(TRUE);
	ComPtr<ICoreWebView2Settings4> settings4;
	if (SUCCEEDED(settings.As(&settings4)))
	{
		settings4->put_IsPasswordAutosaveEnabled(TRUE);
		settings4->put_IsGeneralAutofillEnabled(TRUE);
		settings4->put_AreBrowserAcceleratorKeysEnabled(TRUE);
	}

	ComPtr<ICoreWebView2Profile> base = profile();
	ComPtr<ICoreWebView2Profile6> profile6;
	if (base && SUCCEEDED(base.As(&profile6)))
	{
		profile6->put_IsPasswordAutosaveEnabled(TRUE);
		profile6->put_IsGeneralAutofillEnabled(TRUE);
	}
	ComPtr<ICoreWebView2Profile7> profile7;
	if (base && SUCCEEDED(base.As(&profile7)))
	{
		profile7->GetBrowserExtensions(
		    Callback<ICoreWebView2ProfileGetBrowserExtensionsCompletedHandler>(
		        [](HRESULT hr, ICoreWebView2BrowserExtensionList *list) -> HRESULT {
			        UINT count = 0;
			        if (SUCCEEDED(hr) && list && SUCCEEDED(list->get_Count(&count)))
			        {
				        for (UINT i = 0; i < count; ++i)
				        {
					        ComPtr<ICoreWebView2BrowserExtension> extension;
					        if (SUCCEEDED(list->GetValueAtIndex(i, &extension)))
					        {
						        LPWSTR name = nullptr, id = nullptr;
						        extension->get_Name(&name);
						        extension->get_Id(&id);
						        log("existing extension name %s id %s", take(name).c_str(), take(id).c_str());
					        }
				        }
			        }
			        return S_OK;
		        })
		        .Get());
	}
}

ComPtr<ICoreWebView2Profile> Webview::profile()
{
	ComPtr<ICoreWebView2_13>     webview13;
	ComPtr<ICoreWebView2Profile> result;
	if (SUCCEEDED(webview_.As(&webview13)))
	{
		webview13->get_Profile(&result);
	}
	return result;
}

void Webview::reparent(HWND parent)
{
	if (parent == parent_)
	{
		return;
	}
	check(controller_->put_ParentWindow(parent), "put_ParentWindow");
	controller_->NotifyParentWindowPositionChanged();
	parent_ = parent;
}

void Webview::resize(const RECT &bounds)
{
	check(controller_->put_Bounds(bounds), "put_Bounds");
}

void Webview::focus()
{
	check(controller_->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC), "MoveFocus");
}

void Webview::set_visible(bool visible)
{
	check(controller_->put_IsVisible(visible ? TRUE : FALSE), "put_IsVisible");
}

bool Webview::visible()
{
	BOOL visible = FALSE;
	controller_->get_IsVisible(&visible);
	return visible != FALSE;
}

void Webview::close()
{
	check(controller_->Close(), "Close");
}

void Webview::load(Lisp &lisp, const std::string &url, emacs_value callback)
{
	check(webview_->Navigate(widen(url).c_str()), "Navigate");
	// One-shot in effect: the callback is freed after its first call, as in
	// ewv (whose handler also stays registered).
	auto cb         = std::make_shared<GlobalRef>(lisp, callback);
	auto fired      = std::make_shared<bool>(false);
	auto controller = controller_;
	EventRegistrationToken token;
	webview_->add_NavigationCompleted(
	    Callback<ICoreWebView2NavigationCompletedEventHandler>(
	        [cb, fired, controller](ICoreWebView2 *webview, ICoreWebView2NavigationCompletedEventArgs *) -> HRESULT {
		        if (*fired)
		        {
			        return S_OK;
		        }
		        *fired       = true;
		        LPWSTR title = nullptr, source = nullptr;
		        webview->get_DocumentTitle(&title);
		        webview->get_Source(&source);
		        std::string t = take(title), u = take(source);
		        queue_event([cb, t, u](Lisp &lisp) {
			        emacs_value f = cb->get();
			        try
			        {
				        lisp.call(f, {lisp.string(t), lisp.string(u)});
			        }
			        catch (const LispExit &)
			        {
				        cb->free(lisp);
				        throw;
			        }
			        cb->free(lisp);
		        });
		        notify_emacs(parent_of(controller.Get()));
		        return S_OK;
	        })
	        .Get(),
	    &token);
}

void Webview::load_sync(const std::string &url)
{
	bool done = false;
	EventRegistrationToken token;
	webview_->add_NavigationCompleted(
	    Callback<ICoreWebView2NavigationCompletedEventHandler>(
	        [&done](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *) -> HRESULT {
		        done = true;
		        return S_OK;
	        })
	        .Get(),
	    &token);
	HRESULT hr = webview_->Navigate(widen(url).c_str());
	if (SUCCEEDED(hr))
	{
		pump_until([&] { return done; });
	}
	webview_->remove_NavigationCompleted(token);
	check(hr, "Navigate");
}

void Webview::reload()
{
	check(webview_->Reload(), "Reload");
}

void Webview::go_back()
{
	check(webview_->GoBack(), "GoBack");
}

void Webview::go_forward()
{
	check(webview_->GoForward(), "GoForward");
}

bool Webview::can_go_back()
{
	BOOL value = FALSE;
	webview_->get_CanGoBack(&value);
	return value != FALSE;
}

bool Webview::can_go_forward()
{
	BOOL value = FALSE;
	webview_->get_CanGoForward(&value);
	return value != FALSE;
}

std::string Webview::url()
{
	LPWSTR source = nullptr;
	check(webview_->get_Source(&source), "get_Source");
	return take(source);
}

std::string Webview::document_title()
{
	LPWSTR title = nullptr;
	check(webview_->get_DocumentTitle(&title), "get_DocumentTitle");
	return take(title);
}

void Webview::set_on_new_window_requested(Lisp &lisp, emacs_value callback)
{
	auto cb         = share(lisp, callback);
	auto controller = controller_;
	EventRegistrationToken token;
	check(webview_->add_NewWindowRequested(
	          Callback<ICoreWebView2NewWindowRequestedEventHandler>(
	              [cb, controller](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT {
		              LPWSTR uri = nullptr;
		              args->get_Uri(&uri);
		              std::string                         u = take(uri);
		              ComPtr<ICoreWebView2WindowFeatures> features;
		              args->get_WindowFeatures(&features);
		              ComPtr<ICoreWebView2Deferral> deferral;
		              args->GetDeferral(&deferral);
		              ComPtr<ICoreWebView2NewWindowRequestedEventArgs> keep(args);
		              queue_callback([cb, u, features, deferral, keep](Lisp &lisp) {
			              // Complete the deferral whatever Lisp does.
			              struct Complete
			              {
				              ICoreWebView2Deferral *d;
				              ~Complete()
				              {
					              d->Complete();
				              }
			              } complete{deferral.Get()};
			              emacs_value value = lisp.call(cb->get(), {lisp.string(u), window_features_to_lisp(lisp, features.Get())});
			              keep->put_Handled(lisp.is_nil(value) ? FALSE : TRUE);
		              });
		              notify_emacs(parent_of(controller.Get()));
		              return S_OK;
	              })
	              .Get(),
	          &token),
	      "add_NewWindowRequested");
}

void Webview::set_on_focus(Lisp &lisp, emacs_value callback)
{
	auto cb = share(lisp, callback);
	for (bool focused : {true, false})
	{
		auto handler = Callback<ICoreWebView2FocusChangedEventHandler>(
		    [cb, focused](ICoreWebView2Controller *controller, IUnknown *) -> HRESULT {
			    queue_callback([cb, focused](Lisp &lisp) { lisp.call(cb->get(), {lisp.boolean(focused)}); });
			    notify_emacs(parent_of(controller));
			    return S_OK;
		    });
		EventRegistrationToken token;
		if (focused)
		{
			check(controller_->add_GotFocus(handler.Get(), &token), "add_GotFocus");
		}
		else
		{
			check(controller_->add_LostFocus(handler.Get(), &token), "add_LostFocus");
		}
	}
}

void Webview::set_on_navigation_starting(Lisp &lisp, emacs_value callback)
{
	auto cb         = share(lisp, callback);
	auto controller = controller_;
	EventRegistrationToken token;
	check(webview_->add_NavigationStarting(
	          Callback<ICoreWebView2NavigationStartingEventHandler>(
	              [cb, controller](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
		              LPWSTR uri = nullptr;
		              args->get_Uri(&uri);
		              std::string u = take(uri);
		              queue_callback([cb, u](Lisp &lisp) { lisp.call(cb->get(), {lisp.string(u)}); });
		              notify_emacs(parent_of(controller.Get()));
		              return S_OK;
	              })
	              .Get(),
	          &token),
	      "add_NavigationStarting");
}

void Webview::set_on_history_changed(Lisp &lisp, emacs_value callback)
{
	auto cb         = share(lisp, callback);
	auto controller = controller_;
	EventRegistrationToken token;
	check(webview_->add_HistoryChanged(
	          Callback<ICoreWebView2HistoryChangedEventHandler>([cb, controller](ICoreWebView2 *, IUnknown *) -> HRESULT {
		          queue_callback([cb](Lisp &lisp) { lisp.call(cb->get()); });
		          notify_emacs(parent_of(controller.Get()));
		          return S_OK;
	          })
	              .Get(),
	          &token),
	      "add_HistoryChanged");
}

void Webview::set_on_web_message(Lisp &lisp, emacs_value callback)
{
	auto cb         = share(lisp, callback);
	auto controller = controller_;
	EventRegistrationToken token;
	check(webview_->add_WebMessageReceived(
	          Callback<ICoreWebView2WebMessageReceivedEventHandler>(
	              [cb, controller](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
		              LPWSTR source = nullptr, json = nullptr;
		              HRESULT hr = args->get_Source(&source);
		              if (FAILED(hr))
		              {
			              return hr;
		              }
		              hr = args->get_WebMessageAsJson(&json);
		              if (FAILED(hr))
		              {
			              CoTaskMemFree(source);
			              return hr;
		              }
		              std::string s = take(source), j = take(json);
		              queue_callback([cb, s, j](Lisp &lisp) { lisp.call(cb->get(), {lisp.string(s), lisp.string(j)}); });
		              notify_emacs(parent_of(controller.Get()));
		              return S_OK;
	              })
	              .Get(),
	          &token),
	      "add_WebMessageReceived");
}

void Webview::execute_script(Lisp &lisp, const std::string &js, emacs_value callback)
{
	ComPtr<ICoreWebView2_21> webview21;
	check(webview_.As(&webview21), "ICoreWebView2_21 (ExecuteScriptWithResult)");
	auto cb         = std::make_shared<GlobalRef>(lisp, callback);
	auto controller = controller_;
	check(webview21->ExecuteScriptWithResult(
	          widen(js).c_str(),
	          Callback<ICoreWebView2ExecuteScriptWithResultCompletedHandler>(
	              [cb, controller](HRESULT, ICoreWebView2ExecuteScriptResult *result) -> HRESULT {
		              std::string json = "null";
		              LPWSTR      text = nullptr;
		              if (result && SUCCEEDED(result->get_ResultAsJson(&text)))
		              {
			              json = take(text);
		              }
		              queue_event([cb, json](Lisp &lisp) {
			              try
			              {
				              lisp.call(cb->get(), {lisp.string(json)});
			              }
			              catch (const LispExit &)
			              {
				              cb->free(lisp);
				              throw;
			              }
			              cb->free(lisp);
		              });
		              notify_emacs(parent_of(controller.Get()));
		              return S_OK;
	              })
	              .Get()),
	      "ExecuteScriptWithResult");
}

void Webview::eval_js_cdp(const std::string &js)
{
	std::string params = "{\"expression\":" + json_escape(js) + ",\"awaitPromise\":true}";
	check(webview_->CallDevToolsProtocolMethod(
	          L"Runtime.evaluate", widen(params).c_str(),
	          Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>([](HRESULT, LPCWSTR result) -> HRESULT {
		          log("result = %s", result ? narrow(result).c_str() : "");
		          return S_OK;
	          })
	              .Get()),
	      "CallDevToolsProtocolMethod");
}

void Webview::eval_js_sync(const std::string &js)
{
	ComPtr<ICoreWebView2_21> webview21;
	check(webview_.As(&webview21), "ICoreWebView2_21 (ExecuteScriptWithResult)");
	bool done = false;
	check(webview21->ExecuteScriptWithResult(
	          widen(js).c_str(),
	          Callback<ICoreWebView2ExecuteScriptWithResultCompletedHandler>(
	              [&done](HRESULT, ICoreWebView2ExecuteScriptResult *result) -> HRESULT {
		              LPWSTR text = nullptr;
		              if (result && SUCCEEDED(result->get_ResultAsJson(&text)))
		              {
			              log("rt = %s", take(text).c_str());
		              }
		              done = true;
		              return S_OK;
	              })
	              .Get()),
	      "ExecuteScriptWithResult");
	pump_until([&] { return done; });
}

void Webview::add_script_on_document_created(const std::string &js)
{
	bool    done   = false;
	HRESULT result = S_OK;
	check(webview_->AddScriptToExecuteOnDocumentCreated(
	          widen(js).c_str(),
	          Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
	              [&](HRESULT hr, LPCWSTR) -> HRESULT {
		              result = hr;
		              done   = true;
		              return S_OK;
	              })
	              .Get()),
	      "AddScriptToExecuteOnDocumentCreated");
	pump_until([&] { return done; });
	check(result, "AddScriptToExecuteOnDocumentCreated");
}

void Webview::post_web_message_json(const std::string &json)
{
	check(webview_->PostWebMessageAsJson(widen(json).c_str()), "PostWebMessageAsJson");
}

void Webview::set_default_background_color(uint8_t a, uint8_t r, uint8_t g, uint8_t b)
{
	ComPtr<ICoreWebView2Controller2> controller2;
	check(controller_.As(&controller2), "ICoreWebView2Controller2");
	check(controller2->put_DefaultBackgroundColor(COREWEBVIEW2_COLOR{a, r, g, b}), "put_DefaultBackgroundColor");
}

void Webview::set_color_scheme(const std::string &scheme)
{
	COREWEBVIEW2_PREFERRED_COLOR_SCHEME value = scheme == "dark"    ? COREWEBVIEW2_PREFERRED_COLOR_SCHEME_DARK :
	                                            scheme == "light"   ? COREWEBVIEW2_PREFERRED_COLOR_SCHEME_LIGHT :
	                                                                  COREWEBVIEW2_PREFERRED_COLOR_SCHEME_AUTO;
	ComPtr<ICoreWebView2Profile> p = profile();
	if (!p)
	{
		throw std::runtime_error("this WebView2 runtime has no profile API");
	}
	check(p->put_PreferredColorScheme(value), "put_PreferredColorScheme");
}

void Webview::add_extension(const std::string &path)
{
	ComPtr<ICoreWebView2Profile7> profile7;
	ComPtr<ICoreWebView2Profile>  p = profile();
	if (!p || FAILED(p.As(&profile7)))
	{
		throw std::runtime_error("this WebView2 runtime has no browser extension API");
	}
	bool done = false;
	check(profile7->AddBrowserExtension(
	          widen(path).c_str(),
	          Callback<ICoreWebView2ProfileAddBrowserExtensionCompletedHandler>(
	              [&done](HRESULT hr, ICoreWebView2BrowserExtension *extension) -> HRESULT {
		              if (SUCCEEDED(hr) && extension)
		              {
			              LPWSTR name = nullptr, id = nullptr;
			              extension->get_Name(&name);
			              extension->get_Id(&id);
			              log("added extension name %s id %s", take(name).c_str(), take(id).c_str());
		              }
		              else
		              {
			              log("adding extension failed: 0x%08lX", static_cast<unsigned long>(hr));
		              }
		              done = true;
		              return S_OK;
	              })
	              .Get()),
	      "AddBrowserExtension");
	pump_until([&] { return done; });
}

void Webview::open_task_manager()
{
	ComPtr<ICoreWebView2_6> webview6;
	check(webview_.As(&webview6), "ICoreWebView2_6");
	check(webview6->OpenTaskManagerWindow(), "OpenTaskManagerWindow");
}

// ---------------------------------------------------------------------------
// Frame thread hook
// ---------------------------------------------------------------------------

static LRESULT CALLBACK frame_hook(int code, WPARAM wparam, LPARAM lparam)
{
	auto *msg = reinterpret_cast<MSG *>(lparam);
	if (code >= 0 && msg && msg->message == WM_LBUTTONDOWN)
	{
		SetFocus(msg->hwnd);
	}
	return CallNextHookEx(nullptr, code, wparam, lparam);
}

void install_frame_thread_hook(HWND frame)
{
	// Every frame shares one thread, so one hook covers them; it stays until
	// Emacs exits, like ewv's.
	DWORD thread = GetWindowThreadProcessId(frame, nullptr);
	if (!SetWindowsHookExW(WH_GETMESSAGE, frame_hook, dll_instance(), thread))
	{
		check(HRESULT_FROM_WIN32(GetLastError()), "SetWindowsHookExW");
	}
}
}        // namespace winine
