/**

Copyright: Vadim Lopatin 2014-2017, dayllenger 2018
License:   Boost License 1.0
Authors:   Vadim Lopatin, dayllenger
*/
module beamui.style.theme;

import beamui.core.functions;
import beamui.core.logger;
import beamui.core.types;
import beamui.core.units;
import CSS = beamui.css.css;
import beamui.graphics.colors;
import beamui.graphics.drawables;
import beamui.graphics.resources;
import beamui.style.decode_css;
import beamui.style.style;
import beamui.style.types;

/// Theme - a collection of widget styles, custom colors and drawables
final class Theme
{
private:
    struct StyleID
    {
        string name; // name of a widget or custom name
        string widgetID; // id, #id from css
        string sub; // subitem, ::sub from css
    }

    string _name;
    Style defaultStyle;
    Style[StyleID] styles;
    DrawableRef[string] drawables;
    uint[string] colors;

public:
    /// Unique name of theme
    @property string name() const pure { return _name; }

    /// Create empty theme called `name`
    this(string name)
    {
        _name = name;
        defaultStyle = new Style;
    }

    ~this()
    {
        Log.d("Destroying theme");
        eliminate(defaultStyle);
        eliminate(styles);
        foreach (ref dr; drawables)
            dr.clear();
        destroy(drawables);
    }

    /// A root of style hierarchy. Same as `theme.get(null)`
    @property Style root()
    {
        return defaultStyle;
    }

    /// Get a style OR create it if it's not exist
    Style get(TypeInfo_Class widgetType, string widgetID = null, string sub = null)
    {
        // TODO: check correctness
        if (!widgetType)
            return defaultStyle;

        import std.string : split;
        // get short name
        string name = widgetType.name.split('.')[$ - 1];
        // try to find exact style
        auto p = StyleID(name, widgetID, sub) in styles;
        if (!p && widgetID)
        {
            // try to find a style without widget id
            // because otherwise it will create an empty style for every widget
            p = StyleID(name, null, sub) in styles;
        }
        if (p)
        {
            auto style = *p;
            // if this style was created by stylesheet loader, parent may not be set
            // because class hierarhy is not known there
            if (!style.parent)
                style.parent = getParent(widgetType, sub);
            return style;
        }
        else
        {
            // creating style without widget id
            auto style = new Style;
            style.parent = getParent(widgetType, sub);
            styles[StyleID(name, null, sub)] = style;
            return style;
        }
    }

    /// ditto
    private Style get(string widgetTypeName, string widgetID = null, string sub = null)
    {
        if (!widgetTypeName)
            return defaultStyle;

        auto id = StyleID(widgetTypeName, widgetID, sub);
        if (auto p = id in styles)
            return *p;
        else
        {
            auto style = new Style;
            // set parent for #id styles
            if (widgetID)
                style.parent = get(widgetTypeName, null, sub);
            styles[id] = style;
            return style;
        }
    }

    /// Utility - find parent of style
    private Style getParent(TypeInfo_Class widgetType, string sub)
    {
        import std.string : split;
        // if this class is not on top of hierarhy
        if (widgetType.base !is typeid(Object))
        {
            if (sub)
            {
                // inherit only if parent subitem exists
                if (auto psub = StyleID(widgetType.base.name.split('.')[$ - 1], null, sub) in styles)
                    return *psub;
            }
            else
                return get(widgetType.base);
        }
        return defaultStyle;
    }

    /// Create wrapper style of an existing - to modify some base style properties in widget
    Style modifyStyle(Style parent)
    {
        if (parent && parent !is defaultStyle)
        {
            auto s = new Style;
            s.parent = parent;
            // clone state styles
            foreach (item; parent.stateStyles)
            {
                auto clone = item.s.clone();
                clone.parent = s;
                s.stateStyles ~= Style.StateStyle(clone, item.specified, item.enabled);
            }
            return s;
        }
        else
        {
            return new Style;
        }
    }

    /// Get custom drawable
    ref DrawableRef getDrawable(string name)
    {
        if (auto p = name in drawables)
            return *p;
        else
            return _emptyDrawable;
    }
    private DrawableRef _emptyDrawable;

    /// Set custom drawable for theme
    Theme setDrawable(string name, Drawable dr)
    {
        drawables[name] = dr;
        return this;
    }

    /// Get custom color - transparent by default
    uint getColor(string name, uint defaultColor = COLOR_TRANSPARENT)
    {
        return colors.get(name, defaultColor);
    }

    /// Set custom color for theme
    Theme setColor(string name, uint color)
    {
        colors[name] = color;
        return this;
    }

    void onThemeChanged()
    {
        defaultStyle.onThemeChanged();
        foreach (s; styles)
        {
            s.onThemeChanged();
        }
    }

    /// Print out theme stats
    void printStats()
    {
        Log.fd("Theme: %s, styles: %s, drawables: %s, colors: %s", _name, styles.length,
            drawables.length, colors.length);
    }
}

private __gshared Theme _currentTheme;
/// Current theme accessor
@property Theme currentTheme()
{
    return _currentTheme;
}
/// Set a new theme to be current
@property void currentTheme(Theme theme)
{
    eliminate(_currentTheme);
    _currentTheme = theme;
}

shared static ~this()
{
    currentTheme = null;
}

Theme createDefaultTheme()
{
    import beamui.core.config;

    Log.d("Creating default theme");
    auto theme = new Theme("default");

    version (Windows)
    {
        theme.root.fontFace = "Verdana";
    }
    static if (BACKEND_GUI)
    {
        theme.root.fontSize = Dimension.pt(12);

        auto label = theme.get("Label");
        label.alignment(Align.left | Align.vcenter).padding(Insets(2.pt, 4.pt));
        label.getOrCreateState(State.enabled, State.unspecified).textColor(0xa0000000);

        auto mlabel = theme.get("MultilineLabel");
        mlabel.padding(Insets(1.pt)).maxLines(0);

        auto tooltip = theme.get("Label", "tooltip");
        tooltip.padding(Insets(3.pt)).boxShadow(new BoxShadowDrawable(0, 2, 7, 0x888888)).
            backgroundColor(0x222222).textColor(0xeeeeee);

        auto button = theme.get("Button");
        button.alignment(Align.center).padding(Insets(4.pt)).border(new BorderDrawable(0xaaaaaa, 1)).
            textFlags(TextFlag.underlineHotkeys).focusRectColor(0xbbbbbb);
        button.getOrCreateState(State.hovered | State.checked, State.hovered).
            border(new BorderDrawable(0x4e93da, 1));
    }
    else // console
    {
        theme.root.fontSize = 1;
    }
    return theme;
}

/// Load theme from file, null if failed
Theme loadTheme(string name)
{
    import beamui.core.config;

    string filename = resourceList.getPathByID((BACKEND_CONSOLE ? "console_" ~ name : name) ~ ".css");

    if (!filename)
        return null;

    Log.d("Loading theme from file ", filename);
    string src = cast(string)loadResourceBytes(filename);
    if (!src)
        return null;

    auto theme = new Theme(name);
    auto stylesheet = CSS.createStyleSheet(src);
    loadThemeFromCSS(theme, stylesheet);
    return theme;
}

private void loadThemeFromCSS(Theme theme, CSS.StyleSheet stylesheet)
{
    foreach (r; stylesheet.atRules)
    {
        applyAtRule(theme, r);
    }
    foreach (r; stylesheet.rulesets)
    {
        foreach (sel; r.selectors)
        {
            applyRule(theme, sel, r.properties);
        }
    }
}

private void applyAtRule(Theme theme, CSS.AtRule rule)
{
    auto kw = rule.keyword;
    auto ps = rule.properties;
    assert(ps.length > 0);

    if (kw == "define-colors")
    {
        foreach (p; ps)
        {
            string id = p.name;
            uint color = decodeColor(p.value);
            theme.setColor(id, color);
        }
    }
    else if (kw == "define-drawables")
    {
        foreach (p; ps)
        {
            string id = p.name;
            Drawable dr;

            uint color;
            Drawable image;
            decodeBackground(p.value, color, image);

            if (!isFullyTransparentColor(color))
            {
                if (image)
                    dr = new CombinedDrawable(color, image, null, null);
                else
                    dr = new SolidFillDrawable(color);
            }
            else if (image)
                dr = image;

            theme.setDrawable(id, dr);
        }
    }
    else
        Log.w("CSS: unknown at-rule keyword: ", kw);
}

private void applyRule(Theme theme, CSS.Selector selector, CSS.Property[] properties)
{
    auto style = selectStyle(theme, selector);
    if (!style)
        return;
    foreach (p; properties)
    {
        CSS.Token[] tokens = p.value;
        assert(tokens.length > 0);
    Switch:
        switch (p.name)
        {
        case "width":
            style.width = decodeDimension(tokens[0]);
            break;
        case "height":
            style.height = decodeDimension(tokens[0]);
            break;
        case "min-width":
            style.minWidth = decodeDimension(tokens[0]);
            break;
        case "max-width":
            style.maxWidth = decodeDimension(tokens[0]);
            break;
        case "min-height":
            style.minHeight = decodeDimension(tokens[0]);
            break;
        case "max-height":
            style.maxHeight = decodeDimension(tokens[0]);
            break;/+
        case "weight":
            style.weight = to!int(tokens[0].text); // TODO
            break;+/
        case "align":
            style.alignment = decodeAlignment(tokens);
            break;
        case "margin":
            style.margins = decodeInsets(tokens);
            break;
        case "padding":
            style.padding = decodeInsets(tokens);
            break;
        static foreach (s; ["top", "right", "bottom", "left"])
        {
        case "margin-" ~ s:
            Insets insets = style.margins;
            __traits(getMember, insets, s) = decodeDimension(tokens[0]).toDevice;
            style.margins = insets;
            break Switch;
        case "padding-" ~ s:
            Insets insets = style.padding;
            __traits(getMember, insets, s) = decodeDimension(tokens[0]).toDevice;
            style.padding = insets;
            break Switch;
        }
        case "border":
            style.border = decodeBorder(tokens);
            break;
        case "background-color":
            style.backgroundColor = decodeColor(tokens);
            break;
        case "background-image":
            style.backgroundImage = decodeBackgroundImage(tokens);
            break;
        case "background":
            uint color;
            Drawable image;
            decodeBackground(tokens, color, image);
            style.backgroundColor = color;
            style.backgroundImage = image;
            break;
        case "box-shadow":
            style.boxShadow = decodeBoxShadow(tokens);
            break;
        case "font-face":
            style.fontFace = tokens[0].text;
            break;
        case "font-family":
            style.fontFamily = decodeFontFamily(tokens);
            break;
        case "font-size":
            style.fontSize = decodeDimension(tokens[0]);
            break;
        case "font-weight":
            style.fontWeight = cast(ushort)decodeFontWeight(tokens);
            break;
        case "text-flags":
            style.textFlags = decodeTextFlags(tokens);
            break;
        case "max-lines":
            style.maxLines = to!int(tokens[0].text);
            break;
        case "opacity":
            style.alpha = opacityToAlpha(to!float(tokens[0].text));
            break;
        case "color":
            style.textColor = decodeColor(tokens);
            break;
        case "focus-rect-color":
            style.focusRectColor = decodeColor(tokens);
            break;
        default:
            break;
        }
    }
}

private Style selectStyle(Theme theme, CSS.Selector selector)
{
    auto es = selector.entries;
    assert(es.length > 0);

    if (es.length == 1 && es[0].type == CSS.SelectorEntryType.universal)
        return theme.defaultStyle;

    import std.algorithm : find;
    // find first element entry
    es = es.find!(a => a.type == CSS.SelectorEntryType.element);
    if (es.length == 0)
    {
        Log.fe("CSS(%s): there must be an element entry in selector", selector.line);
        return null;
    }
    auto hash = es.find!(a => a.type == CSS.SelectorEntryType.id);
    auto pseudoElement = es.find!(a => a.type == CSS.SelectorEntryType.pseudoElement);
    string id = hash.length > 0 ? hash[0].text : null;
    string sub = pseudoElement.length > 0 ? pseudoElement[0].text : null;
    // find base style
    auto style = theme.get(es[0].text, id, sub);
    // extract state
    State specified;
    State enabled;
    void applyStateFlag(string flag, string stateName, State state)
    {
        bool yes = flag[0] != '!';
        string s = yes ? flag : flag[1 .. $];
        if (s == stateName)
        {
            specified |= state;
            if (yes)
                enabled |= state;
        }
    }
    foreach (e; es)
    {
        if (e.type == CSS.SelectorEntryType.pseudoClass)
        {
            applyStateFlag(e.text, "pressed", State.pressed);
            applyStateFlag(e.text, "focused", State.focused);
            applyStateFlag(e.text, "default", State.default_);
            applyStateFlag(e.text, "hovered", State.hovered);
            applyStateFlag(e.text, "selected", State.selected);
            applyStateFlag(e.text, "checkable", State.checkable);
            applyStateFlag(e.text, "checked", State.checked);
            applyStateFlag(e.text, "enabled", State.enabled);
            applyStateFlag(e.text, "activated", State.activated);
            applyStateFlag(e.text, "window-focused", State.windowFocused);
        }
    }
    return style.getOrCreateState(specified, enabled);
}