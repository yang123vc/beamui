/**
This module contains OpenGL access layer.

To enable OpenGL support, build with version(USE_OPENGL);

Copyright: Vadim Lopatin 2014-2017, dayllenger 2017-2018
License:   Boost License 1.0
Authors:   Vadim Lopatin, dayllenger
*/
module beamui.graphics.glsupport;

import beamui.core.config;

static if (USE_OPENGL):
import beamui.core.functions : eliminate;
import beamui.core.geometry : Point, Rect, RectF;
import beamui.core.linalg;
import beamui.core.logger;
import beamui.graphics.colors : Color, ColorF;
import beamui.graphics.gl.api;
import beamui.graphics.gl.errors;
import beamui.graphics.gl.objects;
import beamui.graphics.gl.program;
package(beamui) import beamui.graphics.gl.objects : glNoContext;

class SolidFillProgram : GLProgram
{
    override @property string vertexSource() const
    {
        return q{
            in vec3 vertexPosition;
            in vec4 vertexColor;
            out vec4 color;
            uniform mat4 MVP;

            void main()
            {
                gl_Position = MVP * vec4(vertexPosition, 1);
                color = vertexColor;
            }
        };
    }

    override @property string fragmentSource() const
    {
        return q{
            in vec4 color;
            out vec4 outColor;

            void main()
            {
                outColor = color;
            }
        };
    }

    protected GLuint vao;
    protected GLint matrixLocation;

    override bool initLocations()
    {
        matrixLocation = getUniformLocation("MVP");
        bindAttribLocation("vertexPosition", 0);
        bindAttribLocation("vertexColor", 1);
        return matrixLocation >= 0;
    }

    void beforeExecute()
    {
        bind();
        checkgl!glUniformMatrix4fv(matrixLocation, 1, false, glSupport.projectionMatrix.m.ptr);
        VAO.bind(vao);
    }

    void createVAO(size_t verticesBufferLength)
    {
        VAO.bind(vao);

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, cast(void*)0);
        glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 0,
                cast(void*)(verticesBufferLength * float.sizeof));

        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
    }

    void destroyVAO()
    {
        VAO.del(vao);
    }
}

class TextureProgram : SolidFillProgram
{
    override @property string vertexSource() const
    {
        return q{
            in vec3 vertexPosition;
            in vec4 vertexColor;
            in vec2 vertexUV;
            out vec4 color;
            out vec2 UV;
            uniform mat4 MVP;

            void main()
            {
                gl_Position = MVP * vec4(vertexPosition, 1);
                color = vertexColor;
                UV = vertexUV;
            }
        };
    }

    override @property string fragmentSource() const
    {
        return q{
            in vec4 color;
            in vec2 UV;
            out vec4 outColor;
            uniform sampler2D tex;

            void main()
            {
                outColor = texture(tex, UV) * color;
            }
        };
    }

    override bool initLocations()
    {
        bindAttribLocation("vertexUV", 2);
        return super.initLocations();
    }

    protected void createVAO(size_t verticesBufferLength, size_t colorsBufferLength)
    {
        VAO.bind(vao);

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, cast(void*)0);
        glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 0,
                cast(void*)(verticesBufferLength * float.sizeof));
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 0,
                cast(void*)((verticesBufferLength + colorsBufferLength) * float.sizeof));

        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
        glEnableVertexAttribArray(2);
    }
}

private __gshared GLBackend _glBackend;
/// Returns GL backend instance. Null if GL is not loaded.
@property GLBackend glSupport() { return _glBackend; }

/// Initialize OpenGL backend (call only when current OpenGL context is initialized)
bool initGLBackend()
{
    import std.string : fromStringz, strip;
    import bindbc.opengl.gl : loadOpenGL;
    import loader = bindbc.loader.sharedlib;
    import bindbc.opengl.config : configured = glSupport;

    if (_glBackend)
        return true;
    glNoContext = false;

    // load bindings first
    version (Android)
    {
        Log.d("initGLBackend");
    }
    else
    {
        loader.resetErrors();
        const support = loadOpenGL();
        if (support != configured)
        {
            Log.e("Errors when loading OpenGL:");
            foreach (e; loader.errors())
            {
                Log.e(strip(fromStringz(e.error)), " - ", strip(fromStringz(e.message)));
            }
            Log.e("Cannot load GL library");
            return false;
        }
    }
    // the version must be >= 3.0
    const char major = glGetString(GL_VERSION)[0];
    if (major >= '3')
    {
        if (GLProgram.determineGLSLVersion())
            Log.v("GL: GLSL version is ", GLProgram.glslVersionInt);
        else
        {
            Log.e("GL: cannot determine GLSL version");
            return false;
        }

        auto bak = new GLBackend;
        if (bak.valid)
        {
            _glBackend = bak;
            Log.v("GL: initialized successfully");
            return true;
        }
        else
            destroy(bak);
    }
    return false;
}

/// Deinitialize GLBackend, destroy all internal shaders, buffers, etc.
void uninitGLSupport()
{
    eliminate(_glBackend);
    glNoContext = true;
}

/// Drawing backend on OpenGL 3.0+
final class GLBackend
{
    @property bool valid() const
    {
        return _solidFillProgram && _textureProgram;
    }
    @property OpenGLQueue queue() { return _queue; }
    /// Projection matrix
    @property ref mat4 projectionMatrix() { return _projectionMatrix; }

    private
    {
        OpenGLQueue _queue;
        /// Current gl buffer width
        int bufferDx;
        /// Current gl buffer height
        int bufferDy;
        mat4 _projectionMatrix;

        SolidFillProgram _solidFillProgram;
        TextureProgram _textureProgram;

        GLuint vbo;
        GLuint ebo;
    }

    this()
    {
        Log.d("GL: creating backend");
        _queue = new OpenGLQueue;
        if (!initShaders())
            Log.e("GL: failed to create shader programs");
    }

    ~this()
    {
        Log.d("GL: uniniting shaders");
        eliminate(_solidFillProgram);
        eliminate(_textureProgram);
        eliminate(_queue);
    }

    private bool initShaders()
    {
        _solidFillProgram = new SolidFillProgram;
        if (!_solidFillProgram.valid)
        {
            destroy(_solidFillProgram);
            _solidFillProgram = null;
            return false;
        }
        _textureProgram = new TextureProgram;
        if (!_textureProgram.valid)
        {
            destroy(_textureProgram);
            _textureProgram = null;
            return false;
        }
        return true;
    }

    void beforeRenderGUI()
    {
        glEnable(GL_BLEND);
        checkgl!glDisable(GL_CULL_FACE);
        checkgl!glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    }

    private void fillBuffers(
        const float[] vertices, const float[] colors,
        const float[] texcoords, const int[] indices)
    {
        assert(_solidFillProgram && _textureProgram);

        resetBindings();

        VBO.bind(vbo);
        VBO.fill(vertices, colors, texcoords);

        EBO.bind(ebo);
        EBO.fill(indices);

        // create vertex array objects and bind vertex buffers to them
        _solidFillProgram.createVAO(vertices.length);
        VBO.bind(vbo);
        EBO.bind(ebo);
        _textureProgram.createVAO(vertices.length, colors.length);
        VBO.bind(vbo);
        EBO.bind(ebo);
    }

    private void destroyBuffers()
    {
        assert(_solidFillProgram && _textureProgram);

        resetBindings();

        _solidFillProgram.destroyVAO();
        _textureProgram.destroyVAO();

        VBO.del(vbo);
        EBO.del(ebo);
    }

    /// This function is needed to draw custom OpenGL scene correctly
    private static void resetBindings()
    {
        GLProgram.unbind();
        VAO.unbind();
        VBO.unbind();
    }

    private void drawLines(int length, int start)
    {
        assert(_solidFillProgram);

        _solidFillProgram.beforeExecute();

        checkgl!glDrawElements(GL_LINES, length, GL_UNSIGNED_INT, cast(void*)(start * 4));
    }

    private void drawSolidFillTriangles(int length, int start)
    {
        assert(_solidFillProgram);

        _solidFillProgram.beforeExecute();

        checkgl!glDrawElements(GL_TRIANGLES, length, GL_UNSIGNED_INT, cast(void*)(start * 4));
    }

    private void drawColorAndTextureTriangles(GLuint texture, bool linear, int length, int start)
    {
        assert(_textureProgram);

        _textureProgram.beforeExecute();

        Tex2D.setup(texture, 0);
        Tex2D.setFiltering(linear, false);

        checkgl!glDrawElements(GL_TRIANGLES, length, GL_UNSIGNED_INT, cast(void*)(start * 4));

        Tex2D.unbind();
    }

    /// Call glFlush
    void flushGL()
    {
        checkgl!glFlush();
    }

    private bool generateMipmap(int dx, int dy, ubyte* pixels, int level, ref ubyte[] dst)
    {
        if ((dx & 1) || (dy & 1) || dx < 2 || dy < 2)
            return false; // size is not even
        int newdx = dx / 2;
        int newdy = dy / 2;
        int newlen = newdx * newdy * 4;
        if (newlen > dst.length)
            dst.length = newlen;
        ubyte* dstptr = dst.ptr;
        ubyte* srcptr = pixels;
        int srcstride = dx * 4;
        foreach (y; 0 .. newdy)
        {
            foreach (x; 0 .. newdx)
            {
                dstptr[0] = cast(ubyte)((srcptr[0 + 0] + srcptr[0 + 4] +srcptr[0 + srcstride] +
                    srcptr[0 + srcstride + 4]) >> 2);
                dstptr[1] = cast(ubyte)((srcptr[1 + 0] + srcptr[1 + 4] +srcptr[1 + srcstride] +
                    srcptr[1 + srcstride + 4]) >> 2);
                dstptr[2] = cast(ubyte)((srcptr[2 + 0] + srcptr[2 + 4] +srcptr[2 + srcstride] +
                    srcptr[2 + srcstride + 4]) >> 2);
                dstptr[3] = cast(ubyte)((srcptr[3 + 0] + srcptr[3 + 4] +srcptr[3 + srcstride] +
                    srcptr[3 + srcstride + 4]) >> 2);
                dstptr += 4;
                srcptr += 8;
            }
            srcptr += srcstride; // skip srcline
        }
        checkgl!glTexImage2D(GL_TEXTURE_2D, level, GL_RGBA, newdx, newdy, 0, GL_RGBA, GL_UNSIGNED_BYTE, dst.ptr);
        return true;
    }

    bool setTextureImage(GLuint texture, int dx, int dy, ubyte* pixels, int mipmapLevels = 0)
    {
        checkError("before setTextureImage");
        Tex2D.bind(texture);
        checkgl!glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        Tex2D.setFiltering(true, mipmapLevels > 1);
        Tex2D.setRepeating(false);

        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, mipmapLevels > 0 ? mipmapLevels - 1 : 0);
        checkgl!glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, dx, dy, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        if (checkError("updateTexture - glTexImage2D"))
        {
            Log.e("GL: cannot set image for texture");
            return false;
        }
        if (mipmapLevels > 1)
        {
            ubyte[] buffer;
            ubyte* src = pixels;
            int ndx = dx;
            int ndy = dy;
            for (int i = 1; i < mipmapLevels; i++)
            {
                if (!generateMipmap(ndx, ndy, src, i, buffer))
                    break;
                ndx /= 2;
                ndy /= 2;
                src = buffer.ptr;
            }
        }
        Tex2D.unbind();
        return true;
    }

    bool setTextureImageAlpha(GLuint texture, int dx, int dy, ubyte* pixels)
    {
        checkError("before setTextureImageAlpha");
        Tex2D.bind(texture);
        checkgl!glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        Tex2D.setFiltering(true, false);
        Tex2D.setRepeating(false);

        glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, dx, dy, 0, GL_ALPHA, GL_UNSIGNED_BYTE, pixels);
        if (checkError("setTextureImageAlpha - glTexImage2D"))
        {
            Log.e("GL: cannot set image for texture");
            return false;
        }
        Tex2D.unbind();
        return true;
    }

    void clearDepthBuffer()
    {
        glClear(GL_DEPTH_BUFFER_BIT);
    }

    void setOrthoProjection(Rect windowRect, Rect view)
    {
        bufferDx = windowRect.width;
        bufferDy = windowRect.height;
        _projectionMatrix.setOrtho(view.left, view.right, view.top, view.bottom, 0.5f, 50.0f);

        checkgl!glViewport(view.left, windowRect.height - view.bottom, view.width, view.height);
    }
}

/// OpenGL GUI rendering queue. It collects gui draw calls, fills a big buffer for vertex data and draws everything
private final class OpenGLQueue
{
    /// OpenGL batch structure - to draw several triangles in single OpenGL call
    private struct OpenGLBatch
    {
        enum BatchType
        {
            line = 0,
            rect,
            triangle,
            texturedRect
        }
        BatchType type;

        GLuint texture;
        int textureDx;
        int textureDy;
        bool textureLinear;

        // length of batch in indices
        int length;
        // offset in index buffer
        int start;
    }

    import beamui.core.collections : Buf;

    Buf!OpenGLBatch batches;
    // a big buffer
    Buf!float _vertices;
    Buf!float _colors;
    Buf!float _texCoords;
    Buf!int _indices;

    /// Draw all
    void flush()
    {
        glSupport.fillBuffers(_vertices[], _colors[], _texCoords[], _indices[]);
        foreach (b; batches)
        {
            final switch (b.type) with (OpenGLBatch.BatchType)
            {
            case line:
                glSupport.drawLines(b.length, b.start);
                break;
            case rect:
                glSupport.drawSolidFillTriangles(b.length, b.start);
                break;
            case triangle:
                glSupport.drawSolidFillTriangles(b.length, b.start);
                break;
            case texturedRect:
                glSupport.drawColorAndTextureTriangles(b.texture, b.textureLinear, b.length, b.start);
                break;
            }
        }
        //Log.d(batches.length, " ", _vertices.length, " ", _colors.length, " ", _texCoords.length, " ", _indices.length);
        glSupport.destroyBuffers();
        batches.clear();
        _vertices.clear();
        _colors.clear();
        _texCoords.clear();
        _indices.clear();
    }

    static immutable float Z_2D = -2.0f;

    /// Add textured rectangle to queue
    void addTexturedRect(GLuint texture, int textureDx, int textureDy, Color color1, Color color2,
            Color color3, Color color4, Rect srcrc, Rect dstrc, bool linear)
    {
        if (texture == 0)
            return;
        if (batches.length == 0 || batches[$ - 1].type != OpenGLBatch.BatchType.texturedRect ||
                batches[$ - 1].texture != texture || batches[$ - 1].textureLinear != linear)
        {
            batches ~= OpenGLBatch(OpenGLBatch.BatchType.texturedRect, texture, textureDx, textureDy, linear);
            if (batches.length > 1)
                batches.unsafe_ref(-1).start = batches[$ - 2].start + batches[$ - 2].length;
        }

        ColorF[4] colors = [ ColorF(color1), ColorF(color2), ColorF(color3), ColorF(color4) ];

        float dstx0 = cast(float)dstrc.left;
        float dsty0 = cast(float)(glSupport.bufferDy - dstrc.top);
        float dstx1 = cast(float)dstrc.right;
        float dsty1 = cast(float)(glSupport.bufferDy - dstrc.bottom);

        float srcx0 = srcrc.left / cast(float)textureDx;
        float srcy0 = srcrc.top / cast(float)textureDy;
        float srcx1 = srcrc.right / cast(float)textureDx;
        float srcy1 = srcrc.bottom / cast(float)textureDy;

        float[3 * 4] vertices = [dstx0, dsty0, Z_2D, dstx0, dsty1, Z_2D, dstx1, dsty0, Z_2D, dstx1, dsty1, Z_2D];

        float[2 * 4] texCoords = [srcx0, srcy0, srcx0, srcy1, srcx1, srcy0, srcx1, srcy1];

        enum verts = 4;
        mixin(add);
    }

    /// Add solid rectangle to queue
    void addSolidRect(RectF dstRect, Color color)
    {
        addGradientRect(dstRect, color, color, color, color);
    }

    /// Add gradient rectangle to queue
    void addGradientRect(RectF rc, Color color1, Color color2, Color color3, Color color4)
    {
        if (batches.length == 0 || batches[$ - 1].type != OpenGLBatch.BatchType.rect)
        {
            batches ~= OpenGLBatch(OpenGLBatch.BatchType.rect);
            if (batches.length > 1)
                batches.unsafe_ref(-1).start = batches[$ - 2].start + batches[$ - 2].length;
        }

        ColorF[4] colors = [ ColorF(color1), ColorF(color2), ColorF(color3), ColorF(color4) ];

        float x0 = rc.left;
        float y0 = glSupport.bufferDy - rc.top;
        float x1 = rc.right;
        float y1 = glSupport.bufferDy - rc.bottom;

        float[3 * 4] vertices = [x0, y0, Z_2D, x0, y1, Z_2D, x1, y0, Z_2D, x1, y1, Z_2D];
        // fill texture coords buffer with zeros
        float[2 * 4] texCoords = 0;

        enum verts = 4;
        mixin(add);
    }

    /// Add triangle to queue
    void addTriangle(Vec2 p1, Vec2 p2, Vec2 p3, Color color1, Color color2, Color color3)
    {
        if (batches.length == 0 || batches[$ - 1].type != OpenGLBatch.BatchType.triangle)
        {
            batches ~= OpenGLBatch(OpenGLBatch.BatchType.triangle);
            if (batches.length > 1)
                batches.unsafe_ref(-1).start = batches[$ - 2].start + batches[$ - 2].length;
        }

        ColorF[3] colors = [ ColorF(color1), ColorF(color2), ColorF(color3) ];

        float x0 = p1.x;
        float y0 = glSupport.bufferDy - p1.y;
        float x1 = p2.x;
        float y1 = glSupport.bufferDy - p2.y;
        float x2 = p3.x;
        float y2 = glSupport.bufferDy - p3.y;

        float[3 * 3] vertices = [x0, y0, Z_2D, x1, y1, Z_2D, x2, y2, Z_2D];
        // fill texture coords buffer with zeros
        float[2 * 3] texCoords = 0;

        enum verts = 3;
        mixin(add);
    }

    /// Add line to queue
    void addLine(Vec2 p1, Vec2 p2, Color color1, Color color2)
    {
        if (batches.length == 0 || batches[$ - 1].type != OpenGLBatch.BatchType.line)
        {
            batches ~= OpenGLBatch(OpenGLBatch.BatchType.line);
            if (batches.length > 1)
                batches.unsafe_ref(-1).start = batches[$ - 2].start + batches[$ - 2].length;
        }

        ColorF[2] colors = [ ColorF(color1), ColorF(color2) ];

        // half-pixel offset is essential for correct result
        float x0 = p1.x + 0.5;
        float y0 = glSupport.bufferDy - p1.y - 0.5;
        float x1 = p2.x + 0.5;
        float y1 = glSupport.bufferDy - p2.y - 0.5;

        float[3 * 2] vertices = [x0, y0, Z_2D, x1, y1, Z_2D];
        // fill texture coords buffer with zeros
        float[2 * 2] texCoords = 0;

        enum verts = 2;
        mixin(add);
    }

    enum add = q{
        int offset = _vertices.length / 3;
        static if (verts == 4)
        {
            // make indices for rectangle (2 triangles == 6 vertexes per rect)
            int[6] indices = [
                offset + 0,
                offset + 1,
                offset + 2,
                offset + 1,
                offset + 2,
                offset + 3 ];
        } else
        static if (verts == 3)
        {
            // make indices for triangles
            int[3] indices = [
                offset + 0,
                offset + 1,
                offset + 2 ];
        } else
        static if (verts == 2)
        {
            // make indices for lines
            int[2] indices = [
                offset + 0,
                offset + 1 ];
        } else
            static assert(0);

        batches.unsafe_ref(-1).length += indices.length;

        _vertices ~= cast(float[])vertices;
        _colors ~= cast(float[])colors;
        _texCoords ~= cast(float[])texCoords;
        _indices ~= cast(int[])indices;
    };
}
