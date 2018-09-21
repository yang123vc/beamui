/**


Copyright: Vadim Lopatin 2016-2017
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.platforms.ansi_console.consoleapp;

import beamui.core.config;

static if (BACKEND_ANSI_CONSOLE):
import beamui.core.logger;
import beamui.graphics.drawbuf;
import beamui.graphics.fonts;
import beamui.platforms.ansi_console.consolefont;
import beamui.platforms.ansi_console.dconsole;
import beamui.platforms.common.platform;
import beamui.widgets.styles;
import beamui.widgets.widget;

class ConsoleWindow : Window
{
    ConsolePlatform _platform;
    ConsoleWindow _parent;

    this(ConsolePlatform platform, dstring caption, Window parent, WindowFlag flags)
    {
        super();
        _platform = platform;
        _parent = cast(ConsoleWindow)parent;
        _w = _platform.console.width;
        _h = _platform.console.height;
        _windowRect = Box(0, 0, _w, _h);
    }

    override void show()
    {
        if (!_mainWidget)
        {
            Log.e("Window is shown without main widget");
            _mainWidget = new Widget;
        }
        _visible = true;
        handleWindowStateChange(WindowState.normal, Box(0, 0, _platform.console.width, _platform.console.height));
        invalidate();
    }

    private dstring _title;

    override @property dstring title() const
    {
        return _title;
    }

    override @property void title(dstring caption)
    {
        _title = caption;
    }

    override @property void icon(DrawBufRef icon)
    {
        // ignore
    }

    override void invalidate()
    {
        _platform.update();
    }

    override void close()
    {
        Log.d("ConsoleWindow.close()");
        _platform.closeWindow(this);
    }

    override @property Window parentWindow()
    {
        return _parent;
    }

    override protected void handleWindowActivityChange(bool isWindowActive)
    {
        super.handleWindowActivityChange(isWindowActive);
    }

    override @property bool isActive()
    {
        // todo
        return true;
    }

    protected bool _visible;
    /// Returns true if window is shown
    @property bool visible()
    {
        return _visible;
    }
}

class ConsolePlatform : Platform
{
    protected Console _console;

    @property Console console()
    {
        return _console;
    }

    protected ANSIConsoleDrawBuf _drawBuf;
    this()
    {
        _console = new Console;
        _console.batchMode = true;
        _console.keyEvent = &onConsoleKey;
        _console.mouseEvent = &onConsoleMouse;
        _console.resizeEvent = &onConsoleResize;
        _console.inputIdleEvent = &onInputIdle;
        _console.init();
        _console.setCursorType(ConsoleCursorType.invisible);
        _uiDialogDisplayMode = DialogDisplayMode.allTypesOfDialogsInPopup;
        _drawBuf = new ANSIConsoleDrawBuf(_console);
    }

    ~this()
    {
        //Log.d("Destroying console");
        //destroy(_console);
        Log.d("Destroying drawbuf");
        destroy(_drawBuf);
    }

    ConsoleWindow[] _windowList;

    override Window createWindow(dstring title, Window parent,
            WindowFlag flags = WindowFlag.resizable, uint width = 0, uint height = 0)
    {
        auto res = new ConsoleWindow(this, title, parent, flags);
        _windowList ~= res;
        return res;
    }

    ConsoleWindow activeWindow()
    {
        if (!_windowList.length)
            return null;
        return _windowList[$ - 1];
    }

    @property DrawBuf drawBuf()
    {
        return _drawBuf;
    }

    protected bool onConsoleKey(KeyEvent event)
    {
        auto w = activeWindow;
        if (!w)
            return false;
        if (w.dispatchKeyEvent(event))
        {
            _needRedraw = true;
            return true;
        }
        return false;
    }

    protected bool onConsoleMouse(MouseEvent event)
    {
        auto w = activeWindow;
        if (!w)
            return false;
        if (w.dispatchMouseEvent(event))
        {
            _needRedraw = true;
            return true;
        }
        return false;
    }

    protected bool onConsoleResize(int width, int height)
    {
        drawBuf.resize(width, height);
        foreach (w; _windowList)
        {
            w.onResize(width, height);
        }
        _needRedraw = true;
        return false;
    }

    protected bool _needRedraw = true;
    void update()
    {
        _needRedraw = true;
    }

    protected void redraw()
    {
        if (!_needRedraw)
            return;
        foreach (w; _windowList)
        {
            if (w.visible)
            {
                _drawBuf.fillRect(Rect(0, 0, w.width, w.height), w.backgroundColor);
                w.onDraw(_drawBuf);
                auto caretRect = w.caretRect;
                if ((w is activeWindow))
                {
                    if (!caretRect.empty)
                    {
                        _drawBuf.console.setCursor(caretRect.left, caretRect.top);
                        _drawBuf.console.setCursorType(w.caretReplace ? ConsoleCursorType.replace
                                : ConsoleCursorType.insert);
                    }
                    else
                    {
                        _drawBuf.console.setCursorType(ConsoleCursorType.invisible);
                    }
                    _drawBuf.console.setWindowCaption(w.title);
                }
            }
        }
        _needRedraw = false;
    }

    protected bool onInputIdle()
    {
        checkClosedWindows();
        foreach (w; _windowList)
        {
            w.pollTimers();
            w.handlePostedEvents();
        }
        checkClosedWindows();
        redraw();
        _console.flush();
        return false;
    }

    protected Window[] _windowsToClose;
    protected void handleCloseWindow(Window w)
    {
        for (int i = 0; i < _windowList.length; i++)
        {
            if (_windowList[i] is w)
            {
                for (int j = i; j + 1 < _windowList.length; j++)
                    _windowList[j] = _windowList[j + 1];
                _windowList[$ - 1] = null;
                _windowList.length--;
                destroy(w);
                return;
            }
        }
    }

    protected void checkClosedWindows()
    {
        for (int i = 0; i < _windowsToClose.length; i++)
        {
            handleCloseWindow(_windowsToClose[i]);
        }
        _windowsToClose.length = 0;
    }

    override void closeWindow(Window w)
    {
        _windowsToClose ~= w;
    }

    override int enterMessageLoop()
    {
        Log.i("Entered message loop");
        while (_console.pollInput())
        {
            if (_windowList.length == 0)
            {
                Log.d("Window count is 0 - exiting message loop");

                break;
            }
        }
        Log.i("Message loop finished - closing windows");
        _windowsToClose ~= _windowList;
        checkClosedWindows();
        Log.i("Exiting from message loop");
        return 0;
    }

    private dstring _clipboardText;

    override bool hasClipboardText(bool mouseBuffer = false)
    {
        return (_clipboardText.length > 0);
    }

    override dstring getClipboardText(bool mouseBuffer = false)
    {
        return _clipboardText;
    }

    override void setClipboardText(dstring text, bool mouseBuffer = false)
    {
        _clipboardText = text;
    }

    override void requestLayout()
    {
        // TODO
    }

    private void onCtrlC()
    {
        Log.w("Ctrl+C pressed - stopping application");
        if (_console)
        {
            _console.stop();
        }
    }
}

/// Drawing buffer - image container which allows to perform some drawing operations
class ANSIConsoleDrawBuf : ConsoleDrawBuf
{
    protected Console _console;
    @property Console console()
    {
        return _console;
    }

    this(Console console)
    {
        _console = console;
        resetClipping();
    }

    ~this()
    {
        Log.d("Calling console.uninit");
        _console.uninit();
    }

    /// Returns current width
    override @property int width()
    {
        return _console.width;
    }
    /// Returns current height
    override @property int height()
    {
        return _console.height;
    }

    /// Reserved for hardware-accelerated drawing - begins drawing batch
    override void beforeDrawing()
    {
        // TODO?
    }
    /// Reserved for hardware-accelerated drawing - ends drawing batch
    override void afterDrawing()
    {
        // TODO?
    }
    /// Returns buffer bits per pixel
    override @property int bpp()
    {
        return 4;
    }
    // returns pointer to ARGB scanline, null if y is out of range or buffer doesn't provide access to its memory
    //uint * scanLine(int y) { return null; }
    /// Resize buffer
    override void resize(int width, int height)
    {
        // IGNORE
        resetClipping();
    }

    //===============================================================
    // Drawing methods

    /// Fill the whole buffer with solid color (no clipping applied)
    override void fill(uint color)
    {
        // TODO
        fillRect(Rect(0, 0, width, height), color);
    }

    private struct RGB
    {
        int r;
        int g;
        int b;
        int match(int rr, int gg, int bb) immutable
        {
            int dr = rr - r;
            int dg = gg - g;
            int db = bb - b;
            if (dr < 0)
                dr = -dr;
            if (dg < 0)
                dg = -dg;
            if (db < 0)
                db = -db;
            return dr + dg + db;
        }
    }

    version (Windows)
    {
        // windows color table
        static immutable RGB[16] CONSOLE_COLORS_RGB = [
            RGB(0,0,0),
            RGB(0,0,128),
            RGB(0,128,0),
            RGB(0,128,128),
            RGB(128,0,0),
            RGB(128,0,128),
            RGB(128,128,0),
            RGB(192,192,192),
            RGB(0x7c,0x7c,0x7c), // ligth gray
            RGB(0,0,255),
            RGB(0,255,0),
            RGB(0,255,255),
            RGB(255,0,0),
            RGB(255,0,255),
            RGB(255,255,0),
            RGB(255,255,255),
        ];
    }
    else
    {
        // linux color table
        static immutable RGB[16] CONSOLE_COLORS_RGB = [
            RGB(0,0,0),
            RGB(128,0,0),
            RGB(0,128,0),
            RGB(128,128,0),
            RGB(0,0,128),
            RGB(128,0,128),
            RGB(0,128,128),
            RGB(192,192,192),
            RGB(0x7c,0x7c,0x7c), // ligth gray
            RGB(255,0,0),
            RGB(0,255,0),
            RGB(255,255,0),
            RGB(0,0,255),
            RGB(255,0,255),
            RGB(0,255,255),
            RGB(255,255,255),
        ];
    }

    static ubyte toConsoleColor(uint color, bool forBackground = false)
    {
        if (forBackground && ((color >> 24) & 0xFF) >= 0x80)
            return CONSOLE_TRANSPARENT_BACKGROUND;
        int r = (color >> 16) & 0xFF;
        int g = (color >> 8) & 0xFF;
        int b = (color >> 0) & 0xFF;
        int bestMatch = CONSOLE_COLORS_RGB[0].match(r, g, b);
        int bestMatchIndex = 0;
        for (int i = 1; i < 16; i++)
        {
            int m = CONSOLE_COLORS_RGB[i].match(r, g, b);
            if (m < bestMatch)
            {
                bestMatch = m;
                bestMatchIndex = i;
            }
        }
        return cast(ubyte)bestMatchIndex;
    }

    static immutable dstring SPACE_STRING = "                                                                                                    " ~ "                                                                                                    " ~ "                                                                                                    " ~ "                                                                                                    " ~ "                                                                                                    ";

    /// Fill rectangle with solid color (clipping is applied)
    override void fillRect(Rect rc, uint color)
    {
        uint alpha = color >> 24;
        if (alpha >= 128)
            return; // transparent
        _console.backgroundColor = toConsoleColor(color);
        if (applyClipping(rc))
        {
            int w = rc.width;
            foreach (y; rc.top .. rc.bottom)
            {
                _console.setCursor(rc.left, y);
                _console.writeText(SPACE_STRING[0 .. w]);
            }
        }
    }

    override void fillGradientRect(Rect rc, uint color1, uint color2, uint color3, uint color4)
    {
        // TODO
        fillRect(rc, color1);
    }

    /// Fill rectangle with solid color and pattern (clipping is applied)
    override void fillRectPattern(Rect rc, uint color, PatternType pattern)
    {
        // default implementation: does not support patterns
        fillRect(rc, color);
    }

    /// Draw pixel at (x, y) with specified color
    override void drawPixel(int x, int y, uint color)
    {
        // TODO
    }

    override void drawChar(int x, int y, dchar ch, uint color, uint bgcolor)
    {
        if (x < _clipRect.left || x >= _clipRect.right || y < _clipRect.top || y >= _clipRect.bottom)
            return;
        ubyte tc = toConsoleColor(color, false);
        ubyte bc = toConsoleColor(bgcolor, true);
        dchar[1] text;
        text[0] = ch;
        _console.textColor = tc;
        _console.backgroundColor = bc;
        _console.setCursor(x, y);
        _console.writeText(cast(dstring)text);
    }

    /// Draw 8bit alpha image - usually font glyph using specified color (clipping is applied)
    override void drawGlyph(int x, int y, Glyph* glyph, uint color)
    {
        // TODO
    }

    /// Draw source buffer rectangle contents to destination buffer
    override void drawFragment(int x, int y, DrawBuf src, Rect srcrect)
    {
        // not supported
    }

    /// Draw source buffer rectangle contents to destination buffer rectangle applying rescaling
    override void drawRescaled(Rect dstrect, DrawBuf src, Rect srcrect)
    {
        // not supported
    }

    override void clear()
    {
        resetClipping();
    }
}

extern (C) void mySignalHandler(int value)
{
    Log.i("Signal handler - signal = ", value);
    auto platform = cast(ConsolePlatform)platform;
    if (platform)
    {
        platform.onCtrlC();
    }
}

/// Entry point for console app
extern (C) int beamuimain(string[] args)
{
    initLogs();
    SCREEN_DPI = 10;
    Platform.setInstance(new ConsolePlatform);
    FontManager.instance = new ConsoleFontManager;
    initResourceManagers();

    version (Windows)
    {
        import core.sys.windows.winuser;

        DOUBLE_CLICK_THRESHOLD_MS = GetDoubleClickTime();
    }
    else
    {
        // set Ctrl+C handler
        import core.sys.posix.signal;

        sigset(SIGINT, &mySignalHandler);
    }

    platform.uiTheme = "default";

    Log.i("Entering UIAppMain: ", args);
    int result = -1;
    version (unittest)
    {
        result = 0;
    }
    else
    {
        try
        {
            result = UIAppMain(args);
            Log.i("UIAppMain returned ", result);
        }
        catch (Exception e)
        {
            Log.e("Abnormal UIAppMain termination");
            Log.e("UIAppMain exception: ", e);
        }
    }

    Platform.setInstance(null);

    releaseResourcesOnAppExit();

    Log.d("Exiting main");
    debug APP_IS_SHUTTING_DOWN = true;

    return result;
}