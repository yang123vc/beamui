/**
This module contains implementation of SDL2 based backend for dlang library.


Synopsis:
---
import beamui.platforms.sdl.sdlapp;
---

Copyright: Vadim Lopatin 2014-2017, Roman Chistokhodov 2016-2017, Andrzej Kilijański 2017-2018, dayllenger 2018
License:   Boost License 1.0
Authors:   Vadim Lopatin, Andrzej Kilijański
*/
module beamui.platforms.sdl.sdlapp;

import beamui.core.config;

static if (BACKEND_SDL):
import core.runtime;
import std.file;
import std.stdio;
import std.string;
import std.utf : toUTF32, toUTF16z;
import derelict.sdl2.sdl;
import beamui.core.events;
import beamui.core.files;
import beamui.core.logger;
import beamui.graphics.drawbuf;
import beamui.graphics.fonts;
import beamui.graphics.ftfonts;
import beamui.graphics.resources;
import beamui.platforms.common.platform;
import beamui.widgets.styles;
import beamui.widgets.widget;
static if (USE_OPENGL)
{
    import beamui.graphics.glsupport;
}

private derelict.util.exception.ShouldThrow missingSymFunc(string symName)
{
    import std.algorithm : equal;
    static import derelict.util.exception;

    foreach (s; ["SDL_DestroyRenderer", "SDL_GL_DeleteContext", "SDL_DestroyWindow", "SDL_PushEvent",
            "SDL_GL_SetAttribute", "SDL_GL_CreateContext", "SDL_GL_SetSwapInterval",
            "SDL_GetError", "SDL_CreateWindow", "SDL_CreateRenderer",
            "SDL_GetWindowSize", "SDL_GL_GetDrawableSize", "SDL_GetWindowID",
            "SDL_SetWindowSize", "SDL_ShowWindow", "SDL_SetWindowTitle",
            "SDL_CreateRGBSurfaceFrom", "SDL_SetWindowIcon",
            "SDL_FreeSurface", "SDL_ShowCursor", "SDL_SetCursor", "SDL_CreateSystemCursor",
            "SDL_CreateTexture", "SDL_DestroyTexture",
            "SDL_UpdateTexture", "SDL_RenderCopy", "SDL_GL_SwapWindow",
            "SDL_GL_MakeCurrent", "SDL_SetRenderDrawColor", "SDL_RenderClear", "SDL_RenderPresent",
            "SDL_GetModState", "SDL_RemoveTimer", "SDL_RemoveTimer", "SDL_PushEvent", "SDL_RegisterEvents",
            "SDL_WaitEvent", "SDL_StartTextInput", "SDL_Quit", "SDL_HasClipboardText",
            "SDL_GetClipboardText", "SDL_free", "SDL_SetClipboardText", "SDL_Init", "SDL_GetNumVideoDisplays"])
    { //"SDL_GetDisplayDPI", "SDL_SetWindowMinimumSize", "SDL_SetWindowMaximumSize"
        if (symName.equal(s)) // Symbol is used
            return derelict.util.exception.ShouldThrow.Yes;
    }
    // Don't throw for unused symbol
    return derelict.util.exception.ShouldThrow.No;
}

private __gshared uint USER_EVENT_ID;
private __gshared uint TIMER_EVENT_ID;
private __gshared uint WINDOW_CLOSE_EVENT_ID;

final class SDLWindow : Window
{
    SDLPlatform _platform;
    SDL_Window* _win;
    SDL_Renderer* _renderer;

    this(SDLPlatform platform, dstring caption, Window parent, WindowFlag flags, uint width = 0, uint height = 0)
    {
        _platform = platform;
        _title = caption;
        _windowState = WindowState.hidden;

        _children.reserve(10);
        _parent = parent;
        if (_parent)
            _parent.addModalChild(this);

        _w = width > 0 ? width : 500;
        _h = height > 0 ? height : 300;
        _flags = flags;

        create();

        if (platform.defaultWindowIcon.length != 0)
            this.icon = getImage(platform.defaultWindowIcon);
    }

    ~this()
    {
        debug Log.d("Destroying SDL window");

        if (_renderer)
            SDL_DestroyRenderer(_renderer);
        static if (USE_OPENGL)
        {
            if (_context)
                SDL_GL_DeleteContext(_context);
        }
        if (_win)
            SDL_DestroyWindow(_win);
        eliminate(_drawbuf);
    }

    @property uint windowID()
    {
        if (_win)
            return SDL_GetWindowID(_win);
        return 0;
    }

    override void postEvent(CustomEvent event)
    {
        super.postEvent(event);
        SDL_Event sdlevent;
        sdlevent.user.type = USER_EVENT_ID;
        sdlevent.user.code = cast(int)event.uniqueID;
        sdlevent.user.windowID = windowID;
        SDL_PushEvent(&sdlevent);
    }

    static if (USE_OPENGL)
    {
        private SDL_GLContext _context;

        private bool createContext(int versionMajor, int versionMinor)
        {
            Log.i("Trying to create OpenGL ", versionMajor, ".", versionMinor, " context");
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, versionMajor);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, versionMinor);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
            // create the actual context and make it current
            _context = SDL_GL_CreateContext(_win);
            if (!_context)
                Log.e("SDL_GL_CreateContext failed: ", fromStringz(SDL_GetError()));
            else
            {
                Log.i("Created successfully");
                // adjust GL version in platform
                _platform.GLVersionMajor = versionMajor;
                _platform.GLVersionMinor = versionMinor;
                bindContext();
                // trying to activate adaptive vsync
                int res = SDL_GL_SetSwapInterval(-1);
                // if it's not supported, work without vsync
                if (res == -1)
                    SDL_GL_SetSwapInterval(0);
            }
            return _context !is null;
        }
    }

    private bool create()
    {
        debug Log.d("Creating SDL window of size ", _w, "x", _h);

        uint sdlWindowFlags = SDL_WINDOW_HIDDEN;
        if (_flags & WindowFlag.resizable)
            sdlWindowFlags |= SDL_WINDOW_RESIZABLE;
        if (_flags & WindowFlag.fullscreen)
            sdlWindowFlags |= SDL_WINDOW_FULLSCREEN;
        if (_flags & WindowFlag.borderless)
            sdlWindowFlags = SDL_WINDOW_BORDERLESS;
        sdlWindowFlags |= SDL_WINDOW_ALLOW_HIGHDPI;
        static if (USE_OPENGL)
        {
            if (openglEnabled)
                sdlWindowFlags |= SDL_WINDOW_OPENGL;
        }
        _win = SDL_CreateWindow(toUTF8(_title).toStringz, SDL_WINDOWPOS_UNDEFINED,
                SDL_WINDOWPOS_UNDEFINED, _w, _h, sdlWindowFlags);
        static if (USE_OPENGL)
        {
            if (!_win && openglEnabled)
            {
                Log.e("SDL_CreateWindow failed - cannot create OpenGL window: ", fromStringz(SDL_GetError()));
                disableOpenGL();
                // recreate w/o OpenGL
                sdlWindowFlags &= ~SDL_WINDOW_OPENGL;
                _win = SDL_CreateWindow(toUTF8(_title).toStringz, SDL_WINDOWPOS_UNDEFINED,
                        SDL_WINDOWPOS_UNDEFINED, _w, _h, sdlWindowFlags);
            }
        }
        if (!_win)
        {
            Log.e("SDL2: Failed to create window: ", fromStringz(SDL_GetError()));
            return false;
        }

        static if (USE_OPENGL)
        {
            if (openglEnabled)
            {
                bool success = createContext(_platform.GLVersionMajor, _platform.GLVersionMinor);
                if (!success)
                {
                    Log.w("trying other versions of OpenGL");
                    // lazy conditions
                    if (_platform.GLVersionMajor >= 4)
                        success = success || createContext(4, 0);
                    success = success || createContext(3, 3);
                    success = success || createContext(3, 2);
                    success = success || createContext(3, 1);
                    success = success || createContext(2, 1);
                    if (!success)
                    {
                        disableOpenGL();
                        _platform.GLVersionMajor = 0;
                        _platform.GLVersionMinor = 0;
                    }
                }
                if (success)
                {
                    if (!initGLSupport(_platform.GLVersionMajor < 3))
                        disableOpenGL();
                }
            }
        }
        if (!openglEnabled)
        {
            _renderer = SDL_CreateRenderer(_win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
            if (!_renderer)
            {
                _renderer = SDL_CreateRenderer(_win, -1, SDL_RENDERER_SOFTWARE);
                if (!_renderer)
                {
                    Log.e("SDL2: Failed to create renderer");
                    return false;
                }
            }
        }
        Log.i(openglEnabled ? "OpenGL is enabled" : "OpenGL is disabled");

        fixSize();
        title = _title;
        int x = 0;
        int y = 0;
        SDL_GetWindowPosition(_win, &x, &y);
        handleWindowStateChange(WindowState.unspecified, Box(x, y, _w, _h));
        return true;
    }

    void fixSize()
    {
        int w = 0;
        int h = 0;
        SDL_GetWindowSize(_win, &w, &h);
        int pxw = 0;
        int pxh = 0;
        SDL_GL_GetDrawableSize(_win, &pxw, &pxh);
        version (Windows)
        {
            // DPI already calculated
        }
        else
        {
            // scale DPI
            if (pxw > w && pxh > h && w > 0 && h > 0)
                SCREEN_DPI = 96 * pxw / w;
        }
        onResize(max(pxw, w), max(pxh, h));
    }

    override void setMinimumSize(Size minSize)
    {
        SDL_SetWindowMinimumSize(_win, max(minSize.w, 0), max(minSize.h, 0));
    }

    override void setMaximumSize(Size maxSize)
    {
        SDL_SetWindowMaximumSize(_win, max(maxSize.w, 0), max(maxSize.h, 0));
    }

    override void show()
    {
        Log.d("SDLWindow.show - ", title);

        if (!_mainWidget)
        {
            Log.e("Window is shown without main widget");
            _mainWidget = new Widget;
        }
        adjustSize();
        adjustPosition();

        _mainWidget.setFocus();

        SDL_ShowWindow(_win);
        fixSize();
        SDL_RaiseWindow(_win);
        invalidate();
    }

    override void close()
    {
        Log.d("SDLWindow.close()");
        _platform.closeWindow(this);
    }

    override protected void handleWindowStateChange(WindowState newState, Box newWindowRect = Box.none)
    {
        super.handleWindowStateChange(newState, newWindowRect);
    }

    override bool setWindowState(WindowState newState, bool activate = false, Box newWindowRect = Box.none)
    {
        if (_win is null)
            return false;

        bool res = false;

        // change state
        switch (newState)
        {
        case WindowState.maximized:
            if (_windowState != WindowState.maximized)
                SDL_MaximizeWindow(_win);
            res = true;
            break;
        case WindowState.minimized:
            if (_windowState != WindowState.minimized)
                SDL_MinimizeWindow(_win);
            res = true;
            break;
        case WindowState.hidden:
            if (_windowState != WindowState.hidden)
                SDL_HideWindow(_win);
            res = true;
            break;
        case WindowState.normal:
            if (_windowState != WindowState.normal)
            {
                SDL_RestoreWindow(_win);
                version (linux)
                {
                    // On linux with Cinnamon desktop, changing window state from for example minimized reset windows size
                    // and/or position to values from create window (last tested on Cinamon 3.4.6 with SDL 2.0.4)
                    //
                    // Steps to reproduce:
                    // Need app with two windows - dlangide for example.
                    // 1. Comment this fix
                    // 2. dub run --force
                    // 3. After first window appear move it and/or change window size
                    // 4. Click on button to open file
                    // 5. Click on window icon minimize in open file dialog
                    // 6. Restore window clicking on taskbar
                    // 7. The first main window has old position/size
                    // Xfce works OK without this fix
                    if (newWindowRect.w == int.min && newWindowRect.h == int.min)
                        SDL_SetWindowSize(_win, _windowRect.w, _windowRect.h);

                    if (newWindowRect.x == int.min && newWindowRect.y == int.min)
                        SDL_SetWindowPosition(_win, _windowRect.x, _windowRect.y);
                }
            }
            res = true;
            break;
        default:
            break;
        }

        // change size and/or position
        bool rectChanged = false;
        if (newWindowRect != Box.none && (newState == WindowState.normal ||
                newState == WindowState.unspecified))
        {
            // change position
            if (newWindowRect.x != int.min && newWindowRect.y != int.min)
            {
                SDL_SetWindowPosition(_win, newWindowRect.x, newWindowRect.y);
                rectChanged = true;
                res = true;
            }

            // change size
            if (newWindowRect.w != int.min && newWindowRect.h != int.min)
            {
                SDL_SetWindowSize(_win, newWindowRect.w, newWindowRect.h);
                rectChanged = true;
                res = true;
            }
        }

        if (activate)
        {
            SDL_RaiseWindow(_win);
            res = true;
        }

        //needed here to make _windowRect and _windowState valid before SDL_WINDOWEVENT_RESIZED/SDL_WINDOWEVENT_MOVED/SDL_WINDOWEVENT_MINIMIZED/SDL_WINDOWEVENT_MAXIMIZED etc handled
        //example: change size by resizeWindow() and make some calculations using windowRect
        if (rectChanged)
        {
            handleWindowStateChange(newState, Box(
                newWindowRect.x == int.min ? _windowRect.x : newWindowRect.x,
                newWindowRect.y == int.min ? _windowRect.y : newWindowRect.y,
                newWindowRect.w == int.min ? _windowRect.w : newWindowRect.w,
                newWindowRect.h == int.min ? _windowRect.h : newWindowRect.h));
        }
        else
            handleWindowStateChange(newState, Box.none);

        return res;
    }

    override protected void handleWindowActivityChange(bool isWindowActive)
    {
        super.handleWindowActivityChange(isWindowActive);
    }

    override @property bool isActive()
    {
        uint flags = SDL_GetWindowFlags(_win);
        return (flags & SDL_WINDOW_INPUT_FOCUS) == SDL_WINDOW_INPUT_FOCUS;
    }

    protected dstring _title;

    override @property dstring title() const
    {
        return _title;
    }

    override @property void title(dstring caption)
    {
        _title = caption;
        if (_win)
            SDL_SetWindowTitle(_win, toUTF8(caption).toStringz);
    }

    override @property void icon(DrawBufRef buf)
    {
        auto ic = cast(ColorDrawBuf)buf.get;
        if (!ic)
        {
            Log.e("Trying to set null icon for window");
            return;
        }
        int iconw = 32;
        int iconh = 32;
        auto iconDraw = new ColorDrawBuf(iconw, iconh);
        scope (exit)
            destroy(iconDraw);
        iconDraw.fill(0xFF000000);
        iconDraw.drawRescaled(Rect(0, 0, iconw, iconh), ic, Rect(0, 0, ic.width, ic.height));
        iconDraw.invertAndPreMultiplyAlpha();
        SDL_Surface* surface = SDL_CreateRGBSurfaceFrom(iconDraw.scanLine(0), iconDraw.width,
                iconDraw.height, 32, iconDraw.width * 4, 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000);
        if (surface)
        {
            // The icon is attached to the window pointer
            SDL_SetWindowIcon(_win, surface);
            // ...and the surface containing the icon pixel data is no longer required.
            SDL_FreeSurface(surface);
        }
        else
        {
            Log.e("failed to set window icon");
        }
    }

    override void scheduleAnimation()
    {
        invalidate();
    }

    protected CursorType _lastCursorType = CursorType.none;
    protected SDL_Cursor*[uint] _cursorMap;

    override protected void setCursorType(CursorType cursorType)
    {
        // override to support different mouse cursors
        if (_lastCursorType != cursorType)
        {
            if (cursorType == CursorType.none)
            {
                SDL_ShowCursor(SDL_DISABLE);
                return;
            }
            if (_lastCursorType == CursorType.none)
                SDL_ShowCursor(SDL_ENABLE);
            _lastCursorType = cursorType;
            SDL_Cursor* cursor;
            // check for existing cursor in map
            if (cursorType in _cursorMap)
            {
                //Log.d("changing cursor to ", cursorType);
                cursor = _cursorMap[cursorType];
                if (cursor)
                    SDL_SetCursor(cursor);
                return;
            }
            // create new cursor
            switch (cursorType) with (CursorType)
            {
            case arrow:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW);
                break;
            case ibeam:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_IBEAM);
                break;
            case wait:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_WAIT);
                break;
            case waitArrow:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_WAITARROW);
                break;
            case crosshair:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_CROSSHAIR);
                break;
            case no:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_NO);
                break;
            case hand:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_HAND);
                break;
            case sizeNWSE:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENWSE);
                break;
            case sizeNESW:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENESW);
                break;
            case sizeWE:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEWE);
                break;
            case sizeNS:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENS);
                break;
            case sizeAll:
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEALL);
                break;
            default:
                // TODO: support custom cursors
                cursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW);
                break;
            }
            _cursorMap[cursorType] = cursor;
            if (cursor)
            {
                debug (sdl)
                    Log.d("changing cursor to ", cursorType);
                SDL_SetCursor(cursor);
            }
        }
    }

    SDL_Texture* _texture;
    int _txw;
    int _txh;
    private void updateBufferSize()
    {
        if (_texture && (_txw != _w || _txh != _h))
        {
            SDL_DestroyTexture(_texture);
            _texture = null;
        }
        if (!_texture)
        {
            _texture = SDL_CreateTexture(_renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, //SDL_TEXTUREACCESS_STREAMING,
                    _w, _h);
            _txw = _w;
            _txh = _h;
        }
    }

    DrawBuf _drawbuf;

    void redraw()
    {
        // check if size has been changed
        fixSize();

        if (openglEnabled)
        {
            static if (USE_OPENGL)
                drawUsingOpenGL(_drawbuf);
        }
        else
        {
            // Select the color for drawing.
            ubyte r = cast(ubyte)((_backgroundColor >> 16) & 255);
            ubyte g = cast(ubyte)((_backgroundColor >> 8) & 255);
            ubyte b = cast(ubyte)((_backgroundColor >> 0) & 255);
            SDL_SetRenderDrawColor(_renderer, r, g, b, 255);
            // Clear the entire screen to our selected color.
            SDL_RenderClear(_renderer);

            if (!_drawbuf)
                _drawbuf = new ColorDrawBuf(_w, _h);
            else
                _drawbuf.resize(_w, _h);
            _drawbuf.fill(_backgroundColor);
            onDraw(_drawbuf);

            updateBufferSize();
            SDL_Rect rect;
            rect.w = _drawbuf.width;
            rect.h = _drawbuf.height;
            SDL_UpdateTexture(_texture, &rect, cast(const void*)(cast(ColorDrawBuf)_drawbuf).scanLine(0),
                _drawbuf.width * cast(int)uint.sizeof);
            SDL_RenderCopy(_renderer, _texture, &rect, &rect);

            // Up until now everything was drawn behind the scenes.
            // This will show the new, red contents of the window.
            SDL_RenderPresent(_renderer);
        }
    }

    static if (USE_OPENGL)
    {
        override void bindContext()
        {
            SDL_GL_MakeCurrent(_win, _context);
        }

        override void swapBuffers()
        {
            SDL_GL_SwapWindow(_win);
        }
    }

    protected ButtonDetails _lbutton;
    protected ButtonDetails _mbutton;
    protected ButtonDetails _rbutton;
    ushort convertMouseFlags(uint flags)
    {
        ushort res = 0;
        if (flags & SDL_BUTTON_LMASK)
            res |= MouseFlag.lbutton;
        if (flags & SDL_BUTTON_RMASK)
            res |= MouseFlag.rbutton;
        if (flags & SDL_BUTTON_MMASK)
            res |= MouseFlag.mbutton;
        return res;
    }

    MouseButton convertMouseButton(uint button)
    {
        if (button == SDL_BUTTON_LEFT)
            return MouseButton.left;
        if (button == SDL_BUTTON_RIGHT)
            return MouseButton.right;
        if (button == SDL_BUTTON_MIDDLE)
            return MouseButton.middle;
        return MouseButton.none;
    }

    ushort lastFlags;
    short lastx;
    short lasty;
    void processMouseEvent(MouseAction action, uint button, uint state, int x, int y)
    {
        // correct mouse coordinates for HIGHDPI on mac
        int drawableW = 0;
        int drawableH = 0;
        int winW = 0;
        int winH = 0;
        SDL_GL_GetDrawableSize(_win, &drawableW, &drawableH);
        SDL_GetWindowSize(_win, &winW, &winH);
        if (drawableW != winW || drawableH != winH)
        {
            if (drawableW > 0 && winW > 0 && drawableH > 0 && drawableW > 0)
            {
                x = x * drawableW / winW;
                y = y * drawableH / winH;
            }
        }

        MouseEvent event = null;
        if (action == MouseAction.wheel)
        {
            // handle wheel
            short wheelDelta = cast(short)y;
            if (_keyFlags & KeyFlag.shift)
                lastFlags |= MouseFlag.shift;
            else
                lastFlags &= ~MouseFlag.shift;
            if (_keyFlags & KeyFlag.control)
                lastFlags |= MouseFlag.control;
            else
                lastFlags &= ~MouseFlag.control;
            if (_keyFlags & KeyFlag.alt)
                lastFlags |= MouseFlag.alt;
            else
                lastFlags &= ~MouseFlag.alt;
            if (wheelDelta)
                event = new MouseEvent(action, MouseButton.none, lastFlags, lastx, lasty, wheelDelta);
        }
        else
        {
            lastFlags = convertMouseFlags(state);
            if (_keyFlags & KeyFlag.shift)
                lastFlags |= MouseFlag.shift;
            if (_keyFlags & KeyFlag.control)
                lastFlags |= MouseFlag.control;
            if (_keyFlags & KeyFlag.alt)
                lastFlags |= MouseFlag.alt;
            lastx = cast(short)x;
            lasty = cast(short)y;
            MouseButton btn = convertMouseButton(button);
            event = new MouseEvent(action, btn, lastFlags, lastx, lasty);
        }
        if (event)
        {
            ButtonDetails* pbuttonDetails = null;
            if (button == MouseButton.left)
                pbuttonDetails = &_lbutton;
            else if (button == MouseButton.right)
                pbuttonDetails = &_rbutton;
            else if (button == MouseButton.middle)
                pbuttonDetails = &_mbutton;
            if (pbuttonDetails)
            {
                if (action == MouseAction.buttonDown)
                {
                    pbuttonDetails.down(cast(short)x, cast(short)y, lastFlags);
                }
                else if (action == MouseAction.buttonUp)
                {
                    pbuttonDetails.up(cast(short)x, cast(short)y, lastFlags);
                }
            }
            event.lbutton = _lbutton;
            event.rbutton = _rbutton;
            event.mbutton = _mbutton;
            bool res = dispatchMouseEvent(event);
            if (res)
            {
                debug (mouse)
                    Log.d("Calling update() after mouse event");
                update();
            }
        }
    }

    uint convertKeyCode(uint keyCode)
    {
        switch (keyCode)
        {
        case SDLK_0:
            return KeyCode.alpha0;
        case SDLK_1:
            return KeyCode.alpha1;
        case SDLK_2:
            return KeyCode.alpha2;
        case SDLK_3:
            return KeyCode.alpha3;
        case SDLK_4:
            return KeyCode.alpha4;
        case SDLK_5:
            return KeyCode.alpha5;
        case SDLK_6:
            return KeyCode.alpha6;
        case SDLK_7:
            return KeyCode.alpha7;
        case SDLK_8:
            return KeyCode.alpha8;
        case SDLK_9:
            return KeyCode.alpha9;
        case SDLK_a:
            return KeyCode.A;
        case SDLK_b:
            return KeyCode.B;
        case SDLK_c:
            return KeyCode.C;
        case SDLK_d:
            return KeyCode.D;
        case SDLK_e:
            return KeyCode.E;
        case SDLK_f:
            return KeyCode.F;
        case SDLK_g:
            return KeyCode.G;
        case SDLK_h:
            return KeyCode.H;
        case SDLK_i:
            return KeyCode.I;
        case SDLK_j:
            return KeyCode.J;
        case SDLK_k:
            return KeyCode.K;
        case SDLK_l:
            return KeyCode.L;
        case SDLK_m:
            return KeyCode.M;
        case SDLK_n:
            return KeyCode.N;
        case SDLK_o:
            return KeyCode.O;
        case SDLK_p:
            return KeyCode.P;
        case SDLK_q:
            return KeyCode.Q;
        case SDLK_r:
            return KeyCode.R;
        case SDLK_s:
            return KeyCode.S;
        case SDLK_t:
            return KeyCode.T;
        case SDLK_u:
            return KeyCode.U;
        case SDLK_v:
            return KeyCode.V;
        case SDLK_w:
            return KeyCode.W;
        case SDLK_x:
            return KeyCode.X;
        case SDLK_y:
            return KeyCode.Y;
        case SDLK_z:
            return KeyCode.Z;
        case SDLK_F1:
            return KeyCode.F1;
        case SDLK_F2:
            return KeyCode.F2;
        case SDLK_F3:
            return KeyCode.F3;
        case SDLK_F4:
            return KeyCode.F4;
        case SDLK_F5:
            return KeyCode.F5;
        case SDLK_F6:
            return KeyCode.F6;
        case SDLK_F7:
            return KeyCode.F7;
        case SDLK_F8:
            return KeyCode.F8;
        case SDLK_F9:
            return KeyCode.F9;
        case SDLK_F10:
            return KeyCode.F10;
        case SDLK_F11:
            return KeyCode.F11;
        case SDLK_F12:
            return KeyCode.F12;
        case SDLK_F13:
            return KeyCode.F13;
        case SDLK_F14:
            return KeyCode.F14;
        case SDLK_F15:
            return KeyCode.F15;
        case SDLK_F16:
            return KeyCode.F16;
        case SDLK_F17:
            return KeyCode.F17;
        case SDLK_F18:
            return KeyCode.F18;
        case SDLK_F19:
            return KeyCode.F19;
        case SDLK_F20:
            return KeyCode.F20;
        case SDLK_F21:
            return KeyCode.F21;
        case SDLK_F22:
            return KeyCode.F22;
        case SDLK_F23:
            return KeyCode.F23;
        case SDLK_F24:
            return KeyCode.F24;
        case SDLK_BACKSPACE:
            return KeyCode.backspace;
        case SDLK_SPACE:
            return KeyCode.space;
        case SDLK_TAB:
            return KeyCode.tab;
        case SDLK_RETURN:
            return KeyCode.enter;
        case SDLK_ESCAPE:
            return KeyCode.escape;
        case SDLK_DELETE:
        case 0x40000063: // dirty hack for Linux - key on keypad
            return KeyCode.del;
        case SDLK_INSERT:
        case 0x40000062: // dirty hack for Linux - key on keypad
            return KeyCode.ins;
        case SDLK_HOME:
        case 0x4000005f: // dirty hack for Linux - key on keypad
            return KeyCode.home;
        case SDLK_PAGEUP:
        case 0x40000061: // dirty hack for Linux - key on keypad
            return KeyCode.pageUp;
        case SDLK_END:
        case 0x40000059: // dirty hack for Linux - key on keypad
            return KeyCode.end;
        case SDLK_PAGEDOWN:
        case 0x4000005b: // dirty hack for Linux - key on keypad
            return KeyCode.pageDown;
        case SDLK_LEFT:
        case 0x4000005c: // dirty hack for Linux - key on keypad
            return KeyCode.left;
        case SDLK_RIGHT:
        case 0x4000005e: // dirty hack for Linux - key on keypad
            return KeyCode.right;
        case SDLK_UP:
        case 0x40000060: // dirty hack for Linux - key on keypad
            return KeyCode.up;
        case SDLK_DOWN:
        case 0x4000005a: // dirty hack for Linux - key on keypad
            return KeyCode.down;
        case SDLK_KP_ENTER:
            return KeyCode.enter;
        case SDLK_LCTRL:
            return KeyCode.lcontrol;
        case SDLK_LSHIFT:
            return KeyCode.lshift;
        case SDLK_LALT:
            return KeyCode.lalt;
        case SDLK_RCTRL:
            return KeyCode.rcontrol;
        case SDLK_RSHIFT:
            return KeyCode.rshift;
        case SDLK_RALT:
            return KeyCode.ralt;
        case SDLK_LGUI:
            return KeyCode.lwin;
        case SDLK_RGUI:
            return KeyCode.rwin;
        case '/':
            return KeyCode.divide;
        default:
            return 0x10000 | keyCode;
        }
    }

    uint convertKeyFlags(uint flags)
    {
        uint res;
        if (flags & KMOD_CTRL)
            res |= KeyFlag.control;
        if (flags & KMOD_SHIFT)
            res |= KeyFlag.shift;
        if (flags & KMOD_ALT)
            res |= KeyFlag.alt;
        if (flags & KMOD_GUI)
            res |= KeyFlag.menu;
        if (flags & KMOD_RCTRL)
            res |= KeyFlag.rcontrol | KeyFlag.control;
        if (flags & KMOD_RSHIFT)
            res |= KeyFlag.rshift | KeyFlag.shift;
        if (flags & KMOD_RALT)
            res |= KeyFlag.ralt | KeyFlag.alt;
        if (flags & KMOD_LCTRL)
            res |= KeyFlag.lcontrol | KeyFlag.control;
        if (flags & KMOD_LSHIFT)
            res |= KeyFlag.lshift | KeyFlag.shift;
        if (flags & KMOD_LALT)
            res |= KeyFlag.lalt | KeyFlag.alt;
        return res;
    }

    bool processTextInput(const char* s)
    {
        string str = fromStringz(s).dup;
        dstring ds = toUTF32(str);
        uint flags = convertKeyFlags(SDL_GetModState());
        //do not handle Ctrl+Space as text https://github.com/buggins/dlangui/issues/160
        //but do hanlde RAlt https://github.com/buggins/dlangide/issues/129
        debug (keys)
            Log.fd("processTextInput char: %s (%s), flags: %04x", ds, cast(int)ds[0], flags);
        if ((flags & KeyFlag.alt) && (flags & KeyFlag.control))
        {
            flags &= (~(KeyFlag.lralt)) & (~(KeyFlag.lrcontrol));
            debug (keys)
                Log.fd("processTextInput removed Ctrl+Alt flags char: %s (%s), flags: %04x",
                        ds, cast(int)ds[0], flags);
        }

        if (flags & KeyFlag.control || (flags & KeyFlag.lalt) == KeyFlag.lalt || flags & KeyFlag.menu)
            return true;

        bool res = dispatchKeyEvent(new KeyEvent(KeyAction.text, 0, flags, ds));
        if (res)
        {
            debug (sdl)
                Log.d("Calling update() after text event");
            update();
        }
        return res;
    }

    static bool isNumLockEnabled()
    {
        version (Windows)
        {
            return !!(GetKeyState(VK_NUMLOCK) & 1);
        }
        else
        {
            return !!(SDL_GetModState() & KMOD_NUM);
        }
    }

    uint _keyFlags;
    bool processKeyEvent(KeyAction action, uint keyCodeIn, uint flags)
    {
        debug (keys)
            Log.fd("processKeyEvent %s, SDL key: 0x%08x, SDL flags: 0x%08x", action, keyCode, flags);

        uint keyCode = convertKeyCode(keyCodeIn);
        flags = convertKeyFlags(flags);
        if (action == KeyAction.keyDown)
        {
            switch (keyCode)
            {
            case KeyCode.alt:
                flags |= KeyFlag.alt;
                break;
            case KeyCode.ralt:
                flags |= KeyFlag.alt | KeyFlag.ralt;
                break;
            case KeyCode.lalt:
                flags |= KeyFlag.alt | KeyFlag.lalt;
                break;
            case KeyCode.control:
                flags |= KeyFlag.control;
                break;
            case KeyCode.lwin:
            case KeyCode.rwin:
                flags |= KeyFlag.menu;
                break;
            case KeyCode.rcontrol:
                flags |= KeyFlag.control | KeyFlag.rcontrol;
                break;
            case KeyCode.lcontrol:
                flags |= KeyFlag.control | KeyFlag.lcontrol;
                break;
            case KeyCode.shift:
                flags |= KeyFlag.shift;
                break;
            case KeyCode.rshift:
                flags |= KeyFlag.shift | KeyFlag.rshift;
                break;
            case KeyCode.lshift:
                flags |= KeyFlag.shift | KeyFlag.lshift;
                break;

            default:
                break;
            }
        }
        _keyFlags = flags;

        debug (keys)
            Log.fd("processKeyEvent %s, converted key: 0x%08x, converted flags: 0x%08x", action, keyCode, flags);

        if (action == KeyAction.keyDown || action == KeyAction.keyUp)
        {
            if ((keyCodeIn >= SDLK_KP_1 && keyCodeIn <= SDLK_KP_0 || keyCodeIn == SDLK_KP_PERIOD //|| keyCodeIn >= 0x40000059 && keyCodeIn
                ) && isNumLockEnabled)
                return false;
        }
        bool res = dispatchKeyEvent(new KeyEvent(action, keyCode, flags));
        //            if ((keyCode & 0x10000) && (keyCode & 0xF000) != 0xF000) {
        //                dchar[1] text;
        //                text[0] = keyCode & 0xFFFF;
        //                res = dispatchKeyEvent(new KeyEvent(KeyAction.text, keyCode, flags, cast(dstring)text)) || res;
        //            }
        if (res)
        {
            debug (redraw)
                Log.d("Calling update() after key event");
            update();
        }
        return res;
    }

    uint _lastRedrawEventCode;

    override void invalidate()
    {
        _platform.sendRedrawEvent(windowID, ++_lastRedrawEventCode);
    }

    void processRedrawEvent(uint code)
    {
        if (code == _lastRedrawEventCode)
            redraw();
    }

    private long _nextExpectedTimerTs;
    private SDL_TimerID _timerID = 0;

    override protected void scheduleSystemTimer(long intervalMillis)
    {
        if (intervalMillis < 10)
            intervalMillis = 10;
        long nextts = currentTimeMillis + intervalMillis;
        if (_timerID && _nextExpectedTimerTs && _nextExpectedTimerTs < nextts + 10)
            return; // don't reschedule timer, timer event will be received soon
        if (_win)
        {
            if (_timerID)
            {
                SDL_RemoveTimer(_timerID);
                _timerID = 0;
            }
            _timerID = SDL_AddTimer(cast(uint)intervalMillis, &myTimerCallbackFunc, cast(void*)windowID);
            _nextExpectedTimerTs = nextts;
        }
    }

    void handleTimer(SDL_TimerID timerID)
    {
        SDL_RemoveTimer(_timerID);
        _timerID = 0;
        _nextExpectedTimerTs = 0;
        onTimer();
    }
}

private extern (C) uint myTimerCallbackFunc(uint interval, void* param) nothrow
{
    uint windowID = cast(uint)param;
    SDL_Event sdlevent;
    sdlevent.user.type = TIMER_EVENT_ID;
    sdlevent.user.code = 0;
    sdlevent.user.windowID = windowID;
    SDL_PushEvent(&sdlevent);
    return (interval);
}

class SDLPlatform : Platform
{
    this()
    {
    }

    private SDLWindow[uint] _windowMap;

    ~this()
    {
        eliminate(_windowMap);
    }

    SDLWindow getWindow(uint id)
    {
        return _windowMap.get(id, null);
    }

    override void closeWindow(Window w)
    {
        // send a close event to SDLWindow
        SDLWindow window = cast(SDLWindow)w;
        SDL_Event sdlevent;
        sdlevent.user.type = WINDOW_CLOSE_EVENT_ID;
        sdlevent.user.code = 0;
        sdlevent.user.windowID = window.windowID;
        SDL_PushEvent(&sdlevent);
    }

    override void requestLayout()
    {
        foreach (w; _windowMap)
        {
            w.requestLayout();
            w.invalidate();
        }
    }

    override void onThemeChanged()
    {
        super.onThemeChanged();
        foreach (w; _windowMap)
            w.dispatchThemeChanged();
    }

    private uint _redrawEventID;

    void sendRedrawEvent(uint windowID, uint code)
    {
        if (!_redrawEventID)
            _redrawEventID = SDL_RegisterEvents(1);
        SDL_Event event;
        event.type = _redrawEventID;
        event.user.windowID = windowID;
        event.user.code = code;
        SDL_PushEvent(&event);
    }

    override Window createWindow(dstring title, Window parent,
            WindowFlag flags = WindowFlag.resizable, uint width = 0, uint height = 0)
    {
        setDefaultLanguageAndThemeIfNecessary();
        int oldDPI = SCREEN_DPI;
        int newwidth = width;
        int newheight = height;
        version (Windows)
        {
            newwidth = pt(width);
            newheight = pt(height);
        }
        auto res = new SDLWindow(this, title, parent, flags, newwidth, newheight);
        _windowMap[res.windowID] = res;
        if (sdlUpdateScreenDpi() || oldDPI != SCREEN_DPI)
        {
            version (Windows)
            {
                newwidth = pt(width);
                newheight = pt(height);
                if (newwidth != width || newheight != height)
                    SDL_SetWindowSize(res._win, newwidth, newheight);
            }
            onThemeChanged();
        }
        return res;
    }

    private bool _windowsMinimized;

    override int enterMessageLoop()
    {
        Log.i("entering message loop");
        SDL_Event event;
        bool skipNextQuit;
        while (SDL_WaitEvent(&event))
        {
            bool quit = processSDLEvent(event, skipNextQuit);
            if (quit)
                break;
        }
        Log.i("exiting message loop");
        return 0;
    }

    private uint timestampResizing;

    protected bool processSDLEvent(ref SDL_Event event, ref bool skipNextQuit)
    {
        if (event.type == SDL_QUIT)
        {
            if (!skipNextQuit)
                return true;
            else
                skipNextQuit = false;
        }
        if (_redrawEventID && event.type == _redrawEventID)
        {
            if (event.window.timestamp - timestampResizing <= 1) // TODO: refactor everything
                return false;
            // user defined redraw event
            uint windowID = event.user.windowID;
            SDLWindow w = getWindow(windowID);
            if (w)
            {
                w.processRedrawEvent(event.user.code);
            }
            return false;
        }
        switch (event.type)
        {
        case SDL_WINDOWEVENT:
            // window events
            uint windowID = event.window.windowID;
            SDLWindow w = getWindow(windowID);
            if (!w)
            {
                Log.w("SDL_WINDOWEVENT ", event.window.event, " received with unknown id ", windowID);
                break;
            }
            // found window
            switch (event.window.event)
            {
            case SDL_WINDOWEVENT_RESIZED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_RESIZED - ", w.title,
                            ", pos: ", event.window.data1, ",", event.window.data2);
                // redraw is not needed here: SDL_WINDOWEVENT_RESIZED is following SDL_WINDOWEVENT_SIZE_CHANGED
                // if the size was changed by an external event (window manager, user)
                break;
            case SDL_WINDOWEVENT_SIZE_CHANGED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_SIZE_CHANGED - ", w.title,
                            ", size: ", event.window.data1, ",", event.window.data2);
                w.handleWindowStateChange(WindowState.unspecified, Box(w.windowRect.x,
                        w.windowRect.y, event.window.data1, event.window.data2));
                w.redraw();
                timestampResizing = event.window.timestamp;
                break;
            case SDL_WINDOWEVENT_CLOSE:
                if (!w.hasVisibleModalChild)
                {
                    if (w.handleCanClose())
                    {
                        debug (sdl)
                            Log.d("SDL_WINDOWEVENT_CLOSE win: ", event.window.windowID);
                        _windowMap.remove(windowID);
                        destroy(w);
                    }
                    else
                    {
                        skipNextQuit = true;
                    }
                }
                break;
            case SDL_WINDOWEVENT_SHOWN:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_SHOWN - ", w.title);
                if (w.windowState != WindowState.normal)
                    w.handleWindowStateChange(WindowState.normal);
                if (!_windowsMinimized && w.hasVisibleModalChild)
                    w.restoreModalChilds();
                break;
            case SDL_WINDOWEVENT_HIDDEN:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_HIDDEN - ", w.title);
                if (w.windowState != WindowState.hidden)
                    w.handleWindowStateChange(WindowState.hidden);
                break;
            case SDL_WINDOWEVENT_EXPOSED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_EXPOSED - ", w.title);
                // process only if this event is not following SDL_WINDOWEVENT_SIZE_CHANGED event
                if (event.window.timestamp - timestampResizing > 1)
                    w.invalidate();
                break;
            case SDL_WINDOWEVENT_MOVED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_MOVED - ", w.title);
                w.handleWindowStateChange(WindowState.unspecified, Box(event.window.data1,
                        event.window.data2, w.windowRect.w, w.windowRect.h));
                if (!_windowsMinimized && w.hasVisibleModalChild)
                    w.restoreModalChilds();
                break;
            case SDL_WINDOWEVENT_MINIMIZED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_MINIMIZED - ", w.title);
                if (w.windowState != WindowState.minimized)
                    w.handleWindowStateChange(WindowState.minimized);
                if (!_windowsMinimized && w.hasVisibleModalChild)
                    w.minimizeModalChilds();
                if (!_windowsMinimized && w.flags & WindowFlag.modal)
                    w.minimizeParentWindows();
                _windowsMinimized = true;
                break;
            case SDL_WINDOWEVENT_MAXIMIZED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_MAXIMIZED - ", w.title);
                if (w.windowState != WindowState.maximized)
                    w.handleWindowStateChange(WindowState.maximized);
                _windowsMinimized = false;
                break;
            case SDL_WINDOWEVENT_RESTORED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_RESTORED - ", w.title);
                _windowsMinimized = false;
                if (w.flags & WindowFlag.modal)
                {
                    w.restoreParentWindows();
                    w.restore(true);
                }

                if (w.windowState != WindowState.normal)
                    w.handleWindowStateChange(WindowState.normal);

                if (w.hasVisibleModalChild)
                    w.restoreModalChilds();
                version (linux)
                { //not sure if needed on Windows or OSX. Also need to check on FreeBSD
                    w.invalidate();
                }
                break;
            case SDL_WINDOWEVENT_ENTER:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_ENTER - ", w.title);
                break;
            case SDL_WINDOWEVENT_LEAVE:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_LEAVE - ", w.title);
                break;
            case SDL_WINDOWEVENT_FOCUS_GAINED:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_FOCUS_GAINED - ", w.title);
                if (!_windowsMinimized)
                    w.restoreModalChilds();
                w.handleWindowActivityChange(true);
                break;
            case SDL_WINDOWEVENT_FOCUS_LOST:
                debug (sdl)
                    Log.d("SDL_WINDOWEVENT_FOCUS_LOST - ", w.title);
                w.handleWindowActivityChange(false);
                break;
            default:
                break;
            }
            break;
        case SDL_KEYDOWN:
            SDLWindow w = getWindow(event.key.windowID);
            if (w && !w.hasVisibleModalChild)
            {
                w.processKeyEvent(KeyAction.keyDown, event.key.keysym.sym, event.key.keysym.mod);
                SDL_StartTextInput();
            }
            break;
        case SDL_KEYUP:
            SDLWindow w = getWindow(event.key.windowID);
            if (w)
            {
                if (w.hasVisibleModalChild)
                    w.restoreModalChilds();
                else
                    w.processKeyEvent(KeyAction.keyUp, event.key.keysym.sym, event.key.keysym.mod);
            }
            break;
        case SDL_TEXTEDITING:
            debug (sdl)
                Log.d("SDL_TEXTEDITING");
            break;
        case SDL_TEXTINPUT:
            debug (sdl)
                Log.d("SDL_TEXTINPUT");
            SDLWindow w = getWindow(event.text.windowID);
            if (w && !w.hasVisibleModalChild)
            {
                w.processTextInput(event.text.text.ptr);
            }
            break;
        case SDL_MOUSEMOTION:
            SDLWindow w = getWindow(event.motion.windowID);
            if (w && !w.hasVisibleModalChild)
            {
                w.processMouseEvent(MouseAction.move, 0, event.motion.state, event.motion.x, event.motion.y);
            }
            break;
        case SDL_MOUSEBUTTONDOWN:
            SDLWindow w = getWindow(event.button.windowID);
            if (w && !w.hasVisibleModalChild)
            {
                w.processMouseEvent(MouseAction.buttonDown, event.button.button,
                        event.button.state, event.button.x, event.button.y);
            }
            break;
        case SDL_MOUSEBUTTONUP:
            SDLWindow w = getWindow(event.button.windowID);
            if (w)
            {
                if (w.hasVisibleModalChild)
                    w.restoreModalChilds();
                else
                    w.processMouseEvent(MouseAction.buttonUp, event.button.button,
                            event.button.state, event.button.x, event.button.y);
            }
            break;
        case SDL_MOUSEWHEEL:
            SDLWindow w = getWindow(event.wheel.windowID);
            if (w && !w.hasVisibleModalChild)
            {
                debug (sdl)
                    Log.d("SDL_MOUSEWHEEL x=", event.wheel.x, " y=", event.wheel.y);
                w.processMouseEvent(MouseAction.wheel, 0, 0, event.wheel.x, event.wheel.y);
            }
            break;
        default:
            // not supported event
            if (event.type == USER_EVENT_ID)
            {
                SDLWindow w = getWindow(event.user.windowID);
                if (w)
                {
                    w.handlePostedEvent(cast(uint)event.user.code);
                }
            }
            else if (event.type == TIMER_EVENT_ID)
            {
                SDLWindow w = getWindow(event.user.windowID);
                if (w)
                {
                    w.handleTimer(cast(uint)event.user.code);
                }
            }
            else if (event.type == WINDOW_CLOSE_EVENT_ID)
            {
                SDLWindow windowToClose = getWindow(event.user.windowID);
                if (windowToClose)
                {
                    if (windowToClose.windowID in _windowMap)
                    {
                        Log.i("Platform.closeWindow()");
                        _windowMap.remove(windowToClose.windowID);
                        Log.i("windowMap.length=", _windowMap.length);
                        destroy(windowToClose);
                    }
                }
            }
            break;
        }
        if (_windowMap.length == 0)
        {
            SDL_Quit();
            return true;
        }
        return false;
    }

    /// Check has clipboard text
    override bool hasClipboardText(bool mouseBuffer = false)
    {
        return (SDL_HasClipboardText() == SDL_TRUE);
    }

    /// Retrieve text from clipboard (when mouseBuffer == true, use mouse selection clipboard - under linux)
    override dstring getClipboardText(bool mouseBuffer = false)
    {
        char* txt = SDL_GetClipboardText();
        if (!txt)
            return ""d;
        string s = fromStringz(txt).dup;
        SDL_free(txt);
        return normalizeEOLs(toUTF32(s));
    }

    /// Set text to clipboard (when mouseBuffer == true, use mouse selection clipboard - under linux)
    override void setClipboardText(dstring text, bool mouseBuffer = false)
    {
        string s = toUTF8(text);
        SDL_SetClipboardText(s.toStringz);
    }
}

version (Windows)
{
    import core.sys.windows.windows;
    import beamui.platforms.windows.win32fonts;

    pragma(lib, "gdi32.lib");
    pragma(lib, "user32.lib");
    extern (Windows) int beamuiWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
    {
        int result;

        try
        {
            Runtime.initialize();

            // call SetProcessDPIAware to support HI DPI - fix by Kapps
            auto ulib = LoadLibraryA("user32.dll");
            alias SetProcessDPIAwareFunc = int function();
            auto setDpiFunc = cast(SetProcessDPIAwareFunc)GetProcAddress(ulib, "SetProcessDPIAware");
            if (setDpiFunc) // Should never fail, but just in case...
                setDpiFunc();

            // Get screen DPI
            HDC dc = CreateCompatibleDC(NULL);
            SCREEN_DPI = GetDeviceCaps(dc, LOGPIXELSY);
            DeleteObject(dc);

            Log.i("Win32 API SCREEN_DPI detected as ", SCREEN_DPI);

            //SCREEN_DPI = 96 * 3 / 2;

            result = myWinMain(hInstance, hPrevInstance, lpCmdLine, nCmdShow);
            Log.i("calling Runtime.terminate()");
            // commented out to fix hanging runtime.terminate when there are background threads
            Runtime.terminate();
        }
        catch (Throwable e) // catch any uncaught exceptions
        {
            MessageBoxW(null, toUTF16z(e.toString ~ "\nStack trace:\n" ~ defaultTraceHandler.toString),
                    "Error", MB_OK | MB_ICONEXCLAMATION);
            result = 0; // failed
        }

        return result;
    }

    /// Split command line arg list; prepend with executable file name
    string[] splitCmdLine(string line)
    {
        string[] res;
        res ~= exeFilename();
        int start = 0;
        bool insideQuotes = false;
        for (int i = 0; i <= line.length; i++)
        {
            char ch = i < line.length ? line[i] : 0;
            if (ch == '\"')
            {
                if (insideQuotes)
                {
                    if (i > start)
                        res ~= line[start .. i];
                    start = i + 1;
                    insideQuotes = false;
                }
                else
                {
                    insideQuotes = true;
                    start = i + 1;
                }
            }
            else if (!insideQuotes && (ch == ' ' || ch == '\t' || ch == 0))
            {
                if (i > start)
                {
                    res ~= line[start .. i];
                }
                start = i + 1;
            }
        }
        return res;
    }

    int myWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int iCmdShow)
    {
        //Log.d("myWinMain()");
        string basePath = exePath();
        //Log.i("Current executable: ", exePath());
        string cmdline = fromStringz(lpCmdLine).dup;
        //Log.i("Command line: ", cmdline);
        string[] args = splitCmdLine(cmdline);
        //Log.i("Command line params: ", args);

        return sdlmain(args);
    }
}
else
{
    extern (C) int beamuimain(string[] args)
    {
        return sdlmain(args);
    }
}

/// Try to get screen resolution and update SCREEN_DPI; returns true if SCREEN_DPI is changed (when custom override DPI value is not set)
bool sdlUpdateScreenDpi(int displayIndex = 0)
{
    if (SDL_GetDisplayDPI is null)
    {
        Log.w("SDL_GetDisplayDPI is not found: cannot detect screen DPI");
        return false;
    }
    int numDisplays = SDL_GetNumVideoDisplays();
    if (numDisplays < displayIndex + 1)
        return false;
    float hdpi = 0;
    if (SDL_GetDisplayDPI(displayIndex, null, &hdpi, null))
        return false;
    int idpi = cast(int)hdpi;
    if (idpi < 32 || idpi > 2000)
        return false;
    Log.i("sdlUpdateScreenDpi: systemScreenDPI=", idpi);
    if (overrideScreenDPI != 0)
        Log.i("sdlUpdateScreenDpi: systemScreenDPI is overrided = ", overrideScreenDPI);
    if (systemScreenDPI != idpi)
    {
        Log.i("sdlUpdateScreenDpi: systemScreenDPI is changed from ", systemScreenDPI, " to ", idpi);
        SCREEN_DPI = idpi;
        return (overrideScreenDPI == 0);
    }
    return false;
}

int sdlmain(string[] args)
{
    initLogs();

    if (!initFontManager())
    {
        Log.e("******************************************************************");
        Log.e("No font files found!!!");
        Log.e("Currently, only hardcoded font paths implemented.");
        Log.e("Probably you can modify sdlapp.d to add some fonts for your system.");
        Log.e("TODO: use fontconfig");
        Log.e("******************************************************************");
        assert(false);
    }
    initResourceManagers();

    version (Windows)
    {
        DOUBLE_CLICK_THRESHOLD_MS = GetDoubleClickTime();
    }

    try
    {
        DerelictSDL2.missingSymbolCallback = &missingSymFunc;
        DerelictSDL2.load();
    }
    catch (Exception e)
    {
        Log.e("Cannot load SDL2 library: ", e);
        return 1;
    }

    static if (USE_OPENGL)
    {
        if (!initBasicOpenGL())
            disableOpenGL();
    }

    SDL_DisplayMode displayMode;
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_EVENTS | SDL_INIT_NOPARACHUTE) != 0)
    {
        Log.e("Cannot init SDL2: ", fromStringz(SDL_GetError()));
        return 2;
    }
    scope (exit)
        SDL_Quit();

    USER_EVENT_ID = SDL_RegisterEvents(1);
    TIMER_EVENT_ID = SDL_RegisterEvents(1);
    WINDOW_CLOSE_EVENT_ID = SDL_RegisterEvents(1);

    int request = SDL_GetDesktopDisplayMode(0, &displayMode);

    static if (USE_OPENGL)
    {
        // Set OpenGL attributes
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
        // Share textures between contexts
        SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 1);
    }

    auto sdl = new SDLPlatform;
    Platform.setInstance(sdl);

    sdlUpdateScreenDpi(0);

    platform.uiTheme = "default";

    int res = 0;

    version (unittest)
    {
    }
    else
    {
        res = UIAppMain(args);
    }

    Log.d("Destroying SDL platform");
    Platform.setInstance(null);
    static if (USE_OPENGL)
        glNoContext = true;

    releaseResourcesOnAppExit();

    Log.d("Exiting main");
    debug APP_IS_SHUTTING_DOWN = true;

    return res;
}