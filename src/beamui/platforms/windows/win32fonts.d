/**
Win32 fonts support.

Part of the Win32 platform.

Usually you don't need to use this module directly.

Copyright: Vadim Lopatin 2014-2017
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.platforms.windows.win32fonts;

version (Windows):
import beamui.core.config;

static if (BACKEND_GUI):
import core.sys.windows.windows;
import std.string;
import std.utf;
import beamui.core.logger;
import beamui.graphics.fonts;
import beamui.platforms.windows.win32drawbuf;

private struct FontDef
{
    immutable FontFamily family;
    immutable string face;
    immutable ubyte pitchAndFamily;

    this(FontFamily family, string face, ubyte pitchAndFamily)
    {
        this.family = family;
        this.face = face;
        this.pitchAndFamily = pitchAndFamily;
    }
}

// support of subpixel rendering
// from AntigrainGeometry https://rsdn.ru/forum/src/830679.1
import std.math;

// Sub-pixel energy distribution lookup table.
// See description by Steve Gibson: http://grc.com/cttech.htm
// The class automatically normalizes the coefficients
// in such a way that primary + 2*secondary + 3*tertiary = 1.0
// Also, the input values are in range of 0...NumLevels, output ones
// are 0...255
//---------------------------------
struct lcd_distribution_lut(int maxv = 65)
{
    this(double prim, double second, double tert)
    {
        double norm = (255.0 / (maxv - 1)) / (prim + second * 2 + tert * 2);
        prim *= norm;
        second *= norm;
        tert *= norm;
        for (int i = 0; i < maxv; i++)
        {
            m_primary[i] = cast(ubyte)floor(prim * i);
            m_secondary[i] = cast(ubyte)floor(second * i);
            m_tertiary[i] = cast(ubyte)floor(tert * i);
        }
    }

    uint primary(int v) const
    {
        if (v >= maxv)
        {
            Log.e("pixel value returned from font engine > 64: ", v);
            v = maxv - 1;
        }
        return m_primary[v];
    }

    uint secondary(int v) const
    {
        if (v >= maxv)
        {
            Log.e("pixel value returned from font engine > 64: ", v);
            v = maxv - 1;
        }
        return m_secondary[v];
    }

    uint tertiary(int v) const
    {
        if (v >= maxv)
        {
            Log.e("pixel value returned from font engine > 64: ", v);
            v = maxv - 1;
        }
        return m_tertiary[v];
    }

private:
    ubyte[maxv] m_primary;
    ubyte[maxv] m_secondary;
    ubyte[maxv] m_tertiary;
}

private __gshared lcd_distribution_lut!65 lut;
void initWin32FontsTables()
{
    lut = lcd_distribution_lut!65(0.5, 0.25, 0.125);
}

private int myabs(int n)
{
    return n < 0 ? -n : n;
}

private int colorStat(ubyte* p)
{
    int avg = (cast(int)p[0] + cast(int)p[1] + cast(int)p[2]) / 3;
    return myabs(avg - cast(int)p[0]) + myabs(avg - cast(int)p[1]) + myabs(avg - cast(int)p[2]);
}

private int minIndex(int n0, int n1, int n2)
{
    if (n0 <= n1 && n0 <= n2)
        return 0;
    if (n1 <= n0 && n1 <= n2)
        return 1;
    return n2;
}

// This function prepares the alpha-channel information
// for the glyph averaging the values in accordance with
// the method suggested by Steve Gibson. The function
// extends the width by 4 extra pixels, 2 at the beginning
// and 2 at the end. Also, it doesn't align the new width
// to 4 bytes, that is, the output gm.gmBlackBoxX is the
// actual width of the array.
// returns dst glyph width
//---------------------------------
ushort prepare_lcd_glyph(ubyte* gbuf1, ref GLYPHMETRICS gm, ref ubyte[] gbuf2, ref int shiftedBy)
{
    shiftedBy = 0;
    uint src_stride = (gm.gmBlackBoxX + 3) / 4 * 4;
    uint dst_width = src_stride + 4;
    gbuf2 = new ubyte[dst_width * gm.gmBlackBoxY];

    for (uint y = 0; y < gm.gmBlackBoxY; ++y)
    {
        ubyte* src_ptr = gbuf1 + src_stride * y;
        ubyte* dst_ptr = gbuf2.ptr + dst_width * y;
        for (uint x = 0; x < gm.gmBlackBoxX; ++x)
        {
            uint v = *src_ptr++;
            dst_ptr[0] += lut.tertiary(v);
            dst_ptr[1] += lut.secondary(v);
            dst_ptr[2] += lut.primary(v);
            dst_ptr[3] += lut.secondary(v);
            dst_ptr[4] += lut.tertiary(v);
            ++dst_ptr;
        }
    }
    /*
    int dx = (dst_width - 2) / 3;
    int stats[3] = [0, 0, 0];
    for (uint y = 0; y < gm.gmBlackBoxY; y++) {
        for(uint x = 0; x < dx; ++x)
        {
            for (uint x0 = 0; x0 < 3; x0++) {
                stats[x0] += colorStat(gbuf2.ptr + dst_width * y + x0);
            }
        }
    }
    shiftedBy = 0; //minIndex(stats[0], stats[1], stats[2]);
    if (shiftedBy) {
        for (uint y = 0; y < gm.gmBlackBoxY; y++) {
            ubyte * dst_ptr = gbuf2.ptr + dst_width * y;
            for(uint x = 0; x < gm.gmBlackBoxX; ++x)
            {
                if (x + shiftedBy < gm.gmBlackBoxX)
                    dst_ptr[x] = dst_ptr[x + shiftedBy];
                else
                    dst_ptr[x] = 0;
            }
        }
    }
    */
    return cast(ushort)dst_width;
}

/**
* Font implementation based on Win32 API system fonts.
*/
class Win32Font : Font
{
    override @property const
    {
        int size() { return _size; }
        int height() { return _height; }
        ushort weight() { return _weight; }
        int baseline() { return _baseline; }
        bool italic() { return _italic; }
        string face() { return _face; }
        FontFamily family() { return _family; }

        bool isNull()
        {
            return _hfont is null;
        }
    }

    private
    {
        HFONT _hfont;
        int _dpi;
        int _size;
        int _height;
        ushort _weight;
        int _baseline;
        bool _italic;
        string _face;
        FontFamily _family;
        LOGFONTA _logfont;
        Win32ColorDrawBuf _drawbuf;
        GlyphCache _glyphCache;
    }

    override void clear()
    {
        if (_hfont !is null)
        {
            DeleteObject(_hfont);
            _hfont = NULL;
            _height = 0;
            _baseline = 0;
            _size = 0;
        }
        if (_drawbuf !is null)
        {
            destroy(_drawbuf);
            _drawbuf = null;
        }
    }

    uint getGlyphIndex(dchar code)
    {
        if (_drawbuf is null)
            return 0;
        wchar[2] s;
        wchar[2] g;
        s[0] = cast(wchar)code;
        s[1] = 0;
        g[0] = 0;
        GCP_RESULTSW gcp;
        gcp.lStructSize = GCP_RESULTSW.sizeof;
        gcp.lpOutString = null;
        gcp.lpOrder = null;
        gcp.lpDx = null;
        gcp.lpCaretPos = null;
        gcp.lpClass = null;
        gcp.lpGlyphs = g.ptr;
        gcp.nGlyphs = 2;
        gcp.nMaxFit = 2;

        DWORD res = GetCharacterPlacementW(_drawbuf.dc, s.ptr, 1, 1000, &gcp, 0);
        if (!res)
            return 0;
        return g[0];
    }

    override GlyphRef getCharGlyph(dchar ch, bool withImage = true)
    {
        GlyphRef found = _glyphCache.find(ch);
        if (found !is null)
            return found;
        uint glyphIndex = getGlyphIndex(ch);
        if (!glyphIndex)
        {
            ch = getReplacementChar(ch);
            if (!ch)
                return null;
            glyphIndex = getGlyphIndex(ch);
            if (!glyphIndex)
            {
                ch = getReplacementChar(ch);
                if (!ch)
                    return null;
                glyphIndex = getGlyphIndex(ch);
            }
        }
        if (!glyphIndex)
            return null;
        if (glyphIndex >= 0xFFFF)
            return null;
        GLYPHMETRICS metrics;

        bool needSubpixelRendering = FontManager.subpixelRenderingMode && antialiased;
        MAT2 scaleMatrix = {{0, 1}, {0, 0}, {0, 0}, {0, 1}};

        uint res;
        res = GetGlyphOutlineW(_drawbuf.dc, cast(wchar)ch, GGO_METRICS, &metrics, 0, null, &scaleMatrix);
        if (res == GDI_ERROR)
            return null;

        auto g = new Glyph;
        static if (USE_OPENGL)
        {
            g.id = nextGlyphID();
        }
        //g.blackBoxX = cast(ushort)metrics.gmBlackBoxX;
        //g.blackBoxY = cast(ubyte)metrics.gmBlackBoxY;
        //g.originX = cast(byte)metrics.gmptGlyphOrigin.x;
        //g.originY = cast(byte)metrics.gmptGlyphOrigin.y;
        //g.width = cast(ubyte)metrics.gmCellIncX;
        g.subpixelMode = SubpixelRenderingMode.none;

        if (needSubpixelRendering)
        {
            scaleMatrix.eM11.value = 3; // request glyph 3 times wider for subpixel antialiasing
        }

        int gs = 0;
        // calculate bitmap size
        if (antialiased)
        {
            gs = GetGlyphOutlineW(_drawbuf.dc, cast(wchar)ch, GGO_GRAY8_BITMAP, &metrics, 0, NULL, &scaleMatrix);
        }
        else
        {
            gs = GetGlyphOutlineW(_drawbuf.dc, cast(wchar)ch, GGO_BITMAP, &metrics, 0, NULL, &scaleMatrix);
        }

        if (gs >= 0x10000 || gs < 0)
            return null;

        if (needSubpixelRendering)
        {
            //Log.d("ch=", ch);
            //Log.d("NORMAL:  blackBoxX=", g.blackBoxX, " \tblackBoxY=", g.blackBoxY, " \torigin.x=", g.originX, " \torigin.y=", g.originY, "\tgmCellIncX=", g.width);
            g.blackBoxX = cast(ushort)metrics.gmBlackBoxX;
            g.blackBoxY = cast(ubyte)metrics.gmBlackBoxY;
            g.originX = cast(byte)((metrics.gmptGlyphOrigin.x + 0) / 3);
            g.originY = cast(byte)metrics.gmptGlyphOrigin.y;
            g.widthPixels = cast(ubyte)((metrics.gmCellIncX + 2) / 3);
            g.widthScaled = g.widthPixels << 6;
            g.subpixelMode = FontManager.subpixelRenderingMode;
            //Log.d(" *3   :  blackBoxX=", metrics.gmBlackBoxX, " \tblackBoxY=", metrics.gmBlackBoxY, " \torigin.x=", metrics.gmptGlyphOrigin.x, " \torigin.y=", metrics.gmptGlyphOrigin.y, " \tgmCellIncX=", metrics.gmCellIncX);
            //Log.d("  /3  :  blackBoxX=", g.blackBoxX, " \tblackBoxY=", g.blackBoxY, " \torigin.x=", g.originX, " \torigin.y=", g.originY, "\tgmCellIncX=", g.width);
        }
        else
        {
            g.blackBoxX = cast(ushort)metrics.gmBlackBoxX;
            g.blackBoxY = cast(ubyte)metrics.gmBlackBoxY;
            g.originX = cast(byte)metrics.gmptGlyphOrigin.x;
            g.originY = cast(byte)metrics.gmptGlyphOrigin.y;
            g.widthPixels = cast(ubyte)metrics.gmCellIncX;
            g.widthScaled = g.widthPixels << 6;
        }

        if (g.blackBoxX > 0 && g.blackBoxY > 0)
        {
            g.glyph = new ubyte[g.blackBoxX * g.blackBoxY];
            if (gs > 0)
            {
                if (antialiased)
                {
                    // antialiased glyph
                    ubyte[] glyph = new ubyte[gs];
                    res = GetGlyphOutlineW(_drawbuf.dc, cast(wchar)ch, GGO_GRAY8_BITMAP, //GGO_METRICS
                            &metrics,
                            gs, glyph.ptr, &scaleMatrix);
                    if (res == GDI_ERROR)
                    {
                        return null;
                    }
                    if (needSubpixelRendering)
                    {
                        ubyte[] newglyph;
                        int shiftedBy = 0;
                        g.blackBoxX = prepare_lcd_glyph(glyph.ptr, metrics, newglyph, shiftedBy);
                        g.glyph = newglyph;
                        //g.originX = cast(ubyte)((metrics.gmptGlyphOrigin.x + 2 - shiftedBy) / 3);
                        //g.width = cast(ubyte)((metrics.gmCellIncX  + 2 - shiftedBy) / 3);
                    }
                    else
                    {
                        int glyph_row_size = (g.blackBoxX + 3) / 4 * 4;
                        ubyte* src = glyph.ptr;
                        ubyte* dst = g.glyph.ptr;
                        for (int y = 0; y < g.blackBoxY; y++)
                        {
                            for (int x = 0; x < g.blackBoxX; x++)
                            {
                                dst[x] = _gamma65.correct(src[x]);
                            }
                            src += glyph_row_size;
                            dst += g.blackBoxX;
                        }
                    }
                }
                else
                {
                    // bitmap glyph
                    ubyte[] glyph = new ubyte[gs];
                    res = GetGlyphOutlineW(_drawbuf.dc, cast(wchar)ch, GGO_BITMAP, //GGO_METRICS
                            &metrics, gs,
                            glyph.ptr, &scaleMatrix);
                    if (res == GDI_ERROR)
                    {
                        return null;
                    }
                    int glyph_row_bytes = ((g.blackBoxX + 7) / 8);
                    int glyph_row_size = (glyph_row_bytes + 3) / 4 * 4;
                    ubyte* src = glyph.ptr;
                    ubyte* dst = g.glyph.ptr;
                    for (int y = 0; y < g.blackBoxY; y++)
                    {
                        for (int x = 0; x < g.blackBoxX; x++)
                        {
                            int offset = x >> 3;
                            int shift = 7 - (x & 7);
                            ubyte b = ((src[offset] >> shift) & 1) ? 255 : 0;
                            dst[x] = b;
                        }
                        src += glyph_row_size;
                        dst += g.blackBoxX;
                    }
                }
            }
            else
            {
                // empty glyph
                for (int i = g.blackBoxX * g.blackBoxY - 1; i >= 0; i--)
                    g.glyph[i] = 0;
            }
        }
        // found!
        return _glyphCache.put(ch, cast(GlyphRef)g);
    }

    /// Init from font definition
    bool create(FontDef* def, int size, ushort weight, bool italic)
    {
        if (!isNull())
            clear();
        LOGFONTA lf;
        lf.lfCharSet = ANSI_CHARSET; //DEFAULT_CHARSET;
        lf.lfFaceName[0 .. def.face.length] = def.face;
        lf.lfFaceName[def.face.length] = 0;
        lf.lfHeight = -size; //pixelsToPoints(size);
        lf.lfItalic = italic;
        lf.lfWeight = weight;
        lf.lfOutPrecision = OUT_TT_ONLY_PRECIS; //OUT_OUTLINE_PRECIS; //OUT_TT_ONLY_PRECIS;
        lf.lfClipPrecision = CLIP_DEFAULT_PRECIS;
        //lf.lfQuality = NONANTIALIASED_QUALITY; //ANTIALIASED_QUALITY;
        //lf.lfQuality = PROOF_QUALITY; //ANTIALIASED_QUALITY;
        lf.lfQuality = antialiased ? NONANTIALIASED_QUALITY : ANTIALIASED_QUALITY; //PROOF_QUALITY; //ANTIALIASED_QUALITY; //size < 18 ? NONANTIALIASED_QUALITY : PROOF_QUALITY; //ANTIALIASED_QUALITY;
        lf.lfPitchAndFamily = def.pitchAndFamily;
        _hfont = CreateFontIndirectA(&lf);
        _drawbuf = new Win32ColorDrawBuf(1, 1);
        SelectObject(_drawbuf.dc, _hfont);

        TEXTMETRICW tm;
        GetTextMetricsW(_drawbuf.dc, &tm);

        _size = size;
        _height = tm.tmHeight;
        debug (FontResources)
            Log.d("Win32Font.create: height=", _height, " for size=", _size, "  points=", lf.lfHeight, " dpi=", _dpi);
        _baseline = _height - tm.tmDescent;
        _weight = weight;
        _italic = italic;
        _face = def.face;
        _family = def.family;
        debug (FontResources)
            Log.d("Created font ", _face, " ", _size);
        return true;
    }

    override void checkpoint()
    {
        _glyphCache.checkpoint();
    }

    override void cleanup()
    {
        _glyphCache.cleanup();
    }

    override void clearGlyphCache()
    {
        _glyphCache.clear();
    }
}

/**
* Font manager implementation based on Win32 API system fonts.
*/
class Win32FontManager : FontManager
{
    private FontList _activeFonts;
    private FontDef[] _fontFaces;
    private FontDef*[string] _faceByName;

    /// Override to return list of font faces available
    override FontFaceProps[] getFaces()
    {
        FontFaceProps[] res;
        for (int i = 0; i < _fontFaces.length; i++)
        {
            FontFaceProps item = FontFaceProps(_fontFaces[i].face, _fontFaces[i].family);
            bool found = false;
            for (int j = 0; j < res.length; j++)
            {
                if (res[j].face == item.face)
                {
                    found = true;
                    break;
                }
            }
            if (!found)
                res ~= item;
        }
        return res;
    }

    /// Initialize in constructor
    this()
    {
        debug Log.i("Creating Win32FontManager");
        //instance = this;
        initialize();
    }

    ~this()
    {
        debug Log.i("Destroying Win32FontManager");
    }

    /// Initialize font manager by enumerating of system fonts
    bool initialize()
    {
        debug Log.i("Win32FontManager.initialize()");
        Win32ColorDrawBuf drawbuf = new Win32ColorDrawBuf(1, 1);
        LOGFONTA lf;
        lf.lfCharSet = ANSI_CHARSET; //DEFAULT_CHARSET;
        lf.lfFaceName[0] = 0;
        HDC dc = drawbuf.dc;
        int res = EnumFontFamiliesExA(dc, // handle to DC
                &lf, // font information
                cast(FONTENUMPROCA)&LVWin32FontEnumFontFamExProc, // callback function (FONTENUMPROC)
                cast(LPARAM)(cast(void*)this), // additional data
                0U // not used; must be 0
                );
        destroy(drawbuf);
        Log.i("Found ", _fontFaces.length, " font faces");
        return res != 0;
    }

    /// For returning of not found font
    FontRef _emptyFontRef;

    override protected ref FontRef getFontImpl(int size, ushort weight, bool italic, FontFamily family, string face)
    {
        //Log.i("getFont()");
        FontDef* def = findFace(family, face);
        //Log.i("getFont() found face ", def.face, " by requested face ", face);
        if (def !is null)
        {
            ptrdiff_t index = _activeFonts.find(size, weight, italic, def.family, def.face);
            if (index >= 0)
                return _activeFonts.get(index);
            debug (FontResources)
                Log.d("Creating new font");
            auto item = new Win32Font;
            if (!item.create(def, size, weight, italic))
                return _emptyFontRef;
            debug (FontResources)
                Log.d("Adding to list of active fonts");
            return _activeFonts.add(item);
        }
        else
        {
            return _emptyFontRef;
        }
    }

    /// Find font face definition by family only (try to get one of defaults for family if possible)
    FontDef* findFace(FontFamily family)
    {
        FontDef* res = null;
        switch (family)
        {
        case FontFamily.sans_serif:
            res = findFace("Arial");
            if (res !is null)
                return res;
            res = findFace("Tahoma");
            if (res !is null)
                return res;
            res = findFace("Calibri");
            if (res !is null)
                return res;
            res = findFace("Verdana");
            if (res !is null)
                return res;
            res = findFace("Lucida Sans");
            if (res !is null)
                return res;
            break;
        case FontFamily.serif:
            res = findFace("Times New Roman");
            if (res !is null)
                return res;
            res = findFace("Georgia");
            if (res !is null)
                return res;
            res = findFace("Century Schoolbook");
            if (res !is null)
                return res;
            res = findFace("Bookman Old Style");
            if (res !is null)
                return res;
            break;
        case FontFamily.monospace:
            res = findFace("Courier New");
            if (res !is null)
                return res;
            res = findFace("Lucida Console");
            if (res !is null)
                return res;
            res = findFace("Century Schoolbook");
            if (res !is null)
                return res;
            res = findFace("Bookman Old Style");
            if (res !is null)
                return res;
            break;
        case FontFamily.cursive:
            res = findFace("Comic Sans MS");
            if (res !is null)
                return res;
            res = findFace("Lucida Handwriting");
            if (res !is null)
                return res;
            res = findFace("Monotype Corsiva");
            if (res !is null)
                return res;
            break;
        default:
            break;
        }
        return null;
    }

    /// Find font face definition by face only
    FontDef* findFace(string face)
    {
        if (face.length == 0)
            return null;
        string[] faces = split(face, ",");
        foreach (f; faces)
        {
            if (f in _faceByName)
                return _faceByName[f];
        }
        return null;
    }

    /// Find font face definition by family and face
    FontDef* findFace(FontFamily family, string face)
    {
        // by face only
        FontDef* res = findFace(face);
        if (res !is null)
            return res;
        // best for family
        res = findFace(family);
        if (res !is null)
            return res;
        for (int i = 0; i < _fontFaces.length; i++)
        {
            res = &_fontFaces[i];
            if (res.family == family)
                return res;
        }
        res = findFace(FontFamily.sans_serif);
        if (res !is null)
            return res;
        return &_fontFaces[0];
    }

    /// Register enumerated font
    bool registerFont(FontFamily family, string fontFace, ubyte pitchAndFamily)
    {
        Log.d("registerFont(", family, ", ", fontFace, ")");
        _fontFaces ~= FontDef(family, fontFace, pitchAndFamily);
        _faceByName[fontFace] = &_fontFaces[$ - 1];
        return true;
    }

    /// Clear usage flags for all entries
    override void checkpoint()
    {
        _activeFonts.checkpoint();
    }

    /// Removes entries not used after last call of checkpoint() or cleanup()
    override void cleanup()
    {
        _activeFonts.cleanup();
        //_list.cleanup();
    }

    /// Clears glyph cache
    override void clearGlyphCaches()
    {
        _activeFonts.clearGlyphCache();
    }
}

FontFamily pitchAndFamilyToFontFamily(ubyte flags)
{
    if ((flags & FF_DECORATIVE) == FF_DECORATIVE)
        return FontFamily.fantasy;
    else if ((flags & (FIXED_PITCH)) != 0) // | | MONO_FONT
        return FontFamily.monospace;
    else if ((flags & (FF_ROMAN)) != 0)
        return FontFamily.serif;
    else if ((flags & (FF_SCRIPT)) != 0)
        return FontFamily.cursive;
    return FontFamily.sans_serif;
}

// definition
extern (Windows)
{
    int LVWin32FontEnumFontFamExProc(const(LOGFONTA)* lf, // logical-font data
            const(TEXTMETRICA)* lpntme, // physical-font data
            //ENUMLOGFONTEX *lpelfe,    // logical-font data
            //NEWTEXTMETRICEX *lpntme,  // physical-font data
            DWORD fontType, // type of font
            LPARAM lParam // application-defined data
            )
    {
        //
        //Log.d("LVWin32FontEnumFontFamExProc fontType=", fontType);
        if (fontType == TRUETYPE_FONTTYPE)
        {
            void* p = cast(void*)lParam;
            Win32FontManager fontman = cast(Win32FontManager)p;
            string face = fromStringz(lf.lfFaceName.ptr).dup;
            FontFamily family = pitchAndFamilyToFontFamily(lf.lfPitchAndFamily);
            if (face.length < 2 || face[0] == '@')
                return 1;
            //Log.d("face:", face);
            fontman.registerFont(family, face, lf.lfPitchAndFamily);
        }
        return 1;
    }
}
