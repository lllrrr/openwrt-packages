declare namespace LuCI.form {
  class CBIAbstractSection {
    __init__(map: any, sectionType: any, ...args: any[]): void;
    sectiontype: any;
    map: any;
    config: any;
    optional: boolean | undefined;
    addremove: boolean | undefined;
    dynamic: boolean | undefined;
    anonymous: boolean | undefined;
    sortable: boolean | undefined;
    cloneable: boolean | undefined;
    sectiontitle(section_id: string): string | null | undefined;
    /**
     * Access the parent option container instance.
     *
     * In case this section is nested within an option element container,
     * this property will hold a reference to the parent option instance.
     *
     * If this section is not nested, the property is `null`.
     *
     * @name LuCI.form.AbstractSection.prototype#parentoption
     * @type LuCI.form.AbstractValue
     * @readonly
     */
    /**
     * Enumerate the UCI section IDs covered by this form section element.
     *
     * @abstract
     * @throws {InternalError}
     * Throws an `InternalError` exception if the function is not implemented.
     *
     * @returns {string[]}
     * Returns an array of UCI section IDs covered by this form element.
     * The sections will be rendered in the same order as the returned array.
     */
    cfgsections(): string[];
    /**
     * Filter UCI section IDs to render.
     *
     * The filter function is invoked for each UCI section ID of a given type
     * and controls whether the given UCI section is rendered or ignored by
     * the form section element.
     *
     * The default implementation always returns `true`. User code or
     * classes extending `AbstractSection` may override this function with
     * custom implementations.
     *
     * @abstract
     * @param {string} section_id
     * The UCI section ID to test.
     *
     * @returns {boolean}
     * Returns `true` when the given UCI section ID should be handled and
     * `false` when it should be ignored.
     */
    filter(section_id: string): boolean;
    /**
     * Load the configuration covered by this section.
     *
     * The `load()` function recursively walks the section element tree and
     * invokes the load function of each child option element.
     *
     * @returns {Promise<void>}
     * Returns a promise resolving once the values of all child elements have
     * been loaded. The promise may reject with an error if any of the child
     * elements' load functions rejected with an error.
     */
    load(): Promise<void>;
    /**
     * Parse this sections form input.
     *
     * The `parse()` function recursively walks the section element tree and
     * triggers input value reading and validation for each encountered child
     * option element.
     *
     * Options which are hidden due to unsatisfied dependencies are skipped.
     *
     * @returns {Promise<void>}
     * Returns a promise resolving once the values of all child elements have
     * been parsed. The returned promise is rejected if any parsed values do
     * not meet the validation constraints of their respective elements.
     */
    parse(): Promise<void>;
    /**
     * Add an option tab to the section.
     *
     * The child option elements of a section may be divided into multiple
     * tabs to provide a better overview to the user.
     *
     * Before options can be moved into a tab pane, the corresponding tab
     * has to be defined first, which is done by calling this function.
     *
     * Note that once tabs are defined, user code must use the `taboption()`
     * method to add options to specific tabs. Option elements added by
     * `option()` will not be assigned to any tab and not be rendered in this
     * case.
     *
     * @param {string} name
     * The name of the tab to register. It may be freely chosen and just serves
     * as an identifier to differentiate tabs.
     *
     * @param {string} title
     * The human readable caption of the tab.
     *
     * @param {string} [description]
     * An additional description text for the corresponding tab pane. It is
     * displayed as a text paragraph below the tab but before the tab pane
     * contents. If omitted, no description will be rendered.
     *
     * @throws {Error}
     * Throws an exception if a tab with the same `name` already exists.
     */
    tab(name: string, title: string, description?: string): void;
    /**
     * Add a configuration option widget to the section.
     *
     * Note that [taboption()]{@link LuCI.form.AbstractSection#taboption}
     * should be used instead if this form section element uses tabs.
     *
     * @param {LuCI.form.AbstractValue} optionclass
     * The option class to use for rendering the configuration option. Note
     * that this value must be the class itself, not a class instance obtained
     * from calling `new`. It must also be a class derived from
     * [LuCI.form.AbstractSection]{@link LuCI.form.AbstractSection}.
     *
     * @param {...*} classargs
     * Additional arguments which are passed as-is to the constructor of the
     * given option class. Refer to the class specific constructor
     * documentation for details.
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception in case the passed class value is not a
     * descendant of `AbstractValue`.
     *
     * @returns {LuCI.form.AbstractValue}
     * Returns the instantiated option class instance.
     */
    option(cbiClass: any, ...args: any[]): LuCI.form.CBIAbstractValue;
    /**
     * Add a configuration option widget to a tab of the section.
     *
     * @param {string} tabName
     * The name of the section tab to add the option element to.
     *
     * @param {LuCI.form.AbstractValue} optionclass
     * The option class to use for rendering the configuration option. Note
     * that this value must be the class itself, not a class instance obtained
     * from calling `new`. It must also be a class derived from
     * [LuCI.form.AbstractSection]{@link LuCI.form.AbstractSection}.
     *
     * @param {...*} classargs
     * Additional arguments which are passed as-is to the constructor of the
     * given option class. Refer to the class specific constructor
     * documentation for details.
     *
     * @throws {ReferenceError}
     * Throws a `ReferenceError` exception when the given tab name does not
     * exist.
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception in case the passed class value is not a
     * descendant of `AbstractValue`.
     *
     * @returns {LuCI.form.AbstractValue}
     * Returns the instantiated option class instance.
     */
    taboption(
      tabName: string,
      ...args: any[]
    ): LuCI.form.CBIAbstractSectionValue;
    /**
     * Query underlying option configuration values.
     *
     * This function is sensitive to the amount of arguments passed to it;
     * if only one argument is specified, the configuration values of all
     * options within this section are returned as a dictionary.
     *
     * If both the section ID and an option name are supplied, this function
     * returns the configuration value of the specified option only.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @param {string} [option]
     * The name of the option to query
     *
     * @returns {null|string|string[]|Object<string, null|string|string[]>}
     * Returns either a dictionary of option names and their corresponding
     * configuration values or just a single configuration value, depending
     * on the amount of passed arguments.
     */
    cfgvalue(
      section_id: string,
      option?: string,
      ...args: any[]
    ):
      | null
      | string
      | string[]
      | {
          [x: string]: null | string | string[];
        };
    /**
     * Query the underlying option widget input values.
     *
     * This function is sensitive to the amount of arguments passed to it;
     * if only one argument is specified, the widget input values of all
     * options within this section are returned as a dictionary.
     *
     * If both the section ID and an option name are supplied, this function
     * returns the widget input value of the specified option only.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @param {string} [option]
     * The name of the option to query
     *
     * @returns {null|string|string[]|Object<string, null|string|string[]>}
     * Returns either a dictionary of option names and their corresponding
     * widget input values or just a single widget input value, depending
     * on the amount of passed arguments.
     */
    formvalue(
      section_id: string,
      option?: string,
      ...args: any[]
    ):
      | null
      | string
      | string[]
      | {
          [x: string]: null | string | string[];
        };
    /**
     * Obtain underlying option LuCI.ui widget instances.
     *
     * This function is sensitive to the amount of arguments passed to it;
     * if only one argument is specified, the LuCI.ui widget instances of all
     * options within this section are returned as a dictionary.
     *
     * If both the section ID and an option name are supplied, this function
     * returns the LuCI.ui widget instance value of the specified option only.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @param {string} [option]
     * The name of the option to query
     *
     * @returns {null|LuCI.ui.AbstractElement|Object<string, null|LuCI.ui.AbstractElement>}
     * Returns either a dictionary of option names and their corresponding
     * widget input values or just a single widget input value, depending
     * on the amount of passed arguments.
     */
    getUIElement(
      section_id: string,
      option?: string,
      ...args: any[]
    ):
      | null
      | LuCI.ui.AbstractElement
      | {
          [x: string]: null | LuCI.ui.AbstractElement;
        };
    /**
     * Obtain underlying option objects.
     *
     * This function is sensitive to the amount of arguments passed to it;
     * if no option name is specified, all options within this section are
     * returned as a dictionary.
     *
     * If an option name is supplied, this function returns the matching
     * LuCI.form.AbstractValue instance only.
     *
     * @param {string} [option]
     * The name of the option object to obtain
     *
     * @returns {null|LuCI.form.AbstractValue|Object<string, LuCI.form.AbstractValue>}
     * Returns either a dictionary of option names and their corresponding
     * option instance objects or just a single object instance value,
     * depending on the amount of passed arguments.
     */
    getOption(
      option?: string,
      ...args: any[]
    ):
      | null
      | LuCI.form.AbstractValue
      | {
          [x: string]: LuCI.form.AbstractValue;
        };
    /** @private */
    private renderUCISection;
    /** @private */
    private renderTabContainers;
    /** @private */
    private renderOptions;
    /** @private */
    private checkDepends;
  }
  class CBIMap {
    constructor(config: any, ...args: any[]);
    config: any;
    parsechain: any[] | undefined;
    data: any;
    /**
     * Toggle readonly state of the form.
     *
     * If set to `true`, the Map instance is marked readonly and any form
     * option elements added to it will inherit the readonly state.
     *
     * If left unset, the Map will test the access permission of the primary
     * uci configuration upon loading and mark the form readonly if no write
     * permissions are granted.
     *
     * @name LuCI.form.Map.prototype#readonly
     * @type boolean
     */
    /**
     * Return all DOM nodes within this Map which match the given search
     * parameters. This function is essentially a convenience wrapper around
     * `querySelectorAll()`.
     *
     * This function is sensitive to the amount of arguments passed to it;
     * if only one argument is specified, it is used as selector-expression
     * as-is. When two arguments are passed, the first argument is treated
     * as an attribute name, the second one as an attribute value to match.
     *
     * As an example, `map.findElements('input')` would find all `<input>`
     * nodes while `map.findElements('type', 'text')` would find any DOM node
     * with a `type="text"` attribute.
     *
     * @param {string} selector_or_attrname
     * If invoked with only one parameter, this argument is a
     * `querySelectorAll()` compatible selector expression. If invoked with
     * two parameters, this argument is the attribute name to filter for.
     *
     * @param {string} [attrvalue]
     * In case the function is invoked with two parameters, this argument
     * specifies the attribute value to match.
     *
     * @throws {InternalError}
     * Throws an `InternalError` if more than two function parameters are
     * passed.
     *
     * @returns {NodeList}
     * Returns a (possibly empty) DOM `NodeList` containing the found DOM nodes.
     */
    findElements(...args: any[]): NodeList;
    /**
     * Return the first DOM node within this Map which matches the given search
     * parameters. This function is essentially a convenience wrapper around
     * `findElements()` which only returns the first found node.
     *
     * This function is sensitive to the amount of arguments passed to it;
     * if only one argument is specified, it is used as selector-expression
     * as-is. When two arguments are passed, the first argument is treated
     * as an attribute name, the second one as an attribute value to match.
     *
     * As an example, `map.findElement('input')` would find the first `<input>`
     * node while `map.findElement('type', 'text')` would find the first DOM
     * node with a `type="text"` attribute.
     *
     * @param {string} selector_or_attrname
     * If invoked with only one parameter, this argument is a `querySelector()`
     * compatible selector expression. If invoked with two parameters, this
     * argument is the attribute name to filter for.
     *
     * @param {string} [attrvalue]
     * In case the function is invoked with two parameters, this argument
     * specifies the attribute value to match.
     *
     * @throws {InternalError}
     * Throws an `InternalError` if more than two function parameters are
     * passed.
     *
     * @returns {Node|null}
     * Returns the first found DOM node or `null` if no element matched.
     */
    findElement(...args: any[]): Node | null;
    /**
     * Tie another UCI configuration to the map.
     *
     * By default, a map instance will only load the UCI configuration file
     * specified in the constructor, but sometimes access to values from
     * further configuration files is required. This function allows for such
     * use cases by registering further UCI configuration files which are
     * needed by the map.
     *
     * @param {string} config
     * The additional UCI configuration file to tie to the map. If the given
     * config is in the list of required files already, it will be ignored.
     */
    chain(config: string): void;
    /**
     * Add a configuration section to the map.
     *
     * LuCI forms follow the structure of the underlying UCI configurations.
     * This means that a map, which represents a single UCI configuration, is
     * divided into multiple sections which in turn contain an arbitrary
     * number of options.
     *
     * While UCI itself only knows two kinds of sections - named and anonymous
     * ones - the form class offers various flavors of form section elements
     * to present configuration sections in different ways. Refer to the
     * documentation of the different section classes for details.
     *
     * @param {LuCI.form.AbstractSection} sectionclass
     * The section class to use for rendering the configuration section.
     * Note that this value must be the class itself, not a class instance
     * obtained from calling `new`. It must also be a class derived from
     * `LuCI.form.AbstractSection`.
     *
     * @param {...string} classargs
     * Additional arguments which are passed as-is to the constructor of the
     * given section class. Refer to the class specific constructor
     * documentation for details.
     *
     * @returns {LuCI.form.AbstractSection}
     * Returns the instantiated section class instance.
     */
    section(cbiClass: any, ...args: any[]): LuCI.form.CBIAbstractSection;
    /**
     * Load the configuration covered by this map.
     *
     * The `load()` function first loads all referenced UCI configurations,
     * then it recursively walks the form element tree and invokes the
     * load function of each child element.
     *
     * @returns {Promise<void>}
     * Returns a promise resolving once the entire form completed loading all
     * data. The promise may reject with an error if any configuration failed
     * to load or if any of the child elements' load functions reject with
     * an error.
     */
    load(): Promise<void>;
    readonly: boolean | undefined;
    /**
     * Parse the form input values.
     *
     * The `parse()` function recursively walks the form element tree and
     * triggers input value reading and validation for each child element.
     *
     * Elements which are hidden due to unsatisfied dependencies are skipped.
     *
     * @returns {Promise<void>}
     * Returns a promise resolving once the entire form completed parsing all
     * input values. The returned promise is rejected if any parsed values do
     * not meet the validation constraints of their respective elements.
     */
    parse(): Promise<void>;
    /**
     * Save the form input values.
     *
     * This function parses the current form, saves the resulting UCI changes,
     * reloads the UCI configuration data and redraws the form elements.
     *
     * @param {function} [cb]
     * An optional callback function that is invoked after the form is parsed
     * but before the changed UCI data is saved. This is useful to perform
     * additional data manipulation steps before saving the changes.
     *
     * @param {boolean} [silent=false]
     * If set to `true`, trigger an alert message to the user in case saving
     * the form data fails. Otherwise fail silently.
     *
     * @returns {Promise<void>}
     * Returns a promise resolving once the entire save operation is complete.
     * The returned promise is rejected if any step of the save operation
     * failed.
     */
    save(cb?: (...args: any[]) => any, silent?: boolean): Promise<void>;
    /**
     * Reset the form by re-rendering its contents. This will revert all
     * unsaved user inputs to their initial form state.
     *
     * @returns {Promise<Node>}
     * Returns a promise resolving to the top-level form DOM node once the
     * re-rendering is complete.
     */
    reset(): Promise<Node>;
    /**
     * Render the form markup.
     *
     * @returns {Promise<Node>}
     * Returns a promise resolving to the top-level form DOM node once the
     * rendering is complete.
     */
    render(): Promise<Node>;
    private renderContents;
    /**
     * Find a form option element instance.
     *
     * @param {string} name
     * The name or the full ID of the option element to look up.
     *
     * @param {string} [section_id]
     * The ID of the UCI section that contains the option to look up. May be
     * omitted if a full ID is passed as the first argument.
     *
     * @param {string} [config_name]
     * The name of the UCI configuration the option instance belongs to.
     * Defaults to the main UCI configuration of the map if omitted.
     *
     * @returns {Array<LuCI.form.AbstractValue,string>|null}
     * Returns a two-element array containing the form option instance as
     * the first item and the corresponding UCI section ID as the second item.
     * Returns `null` if the option could not be found.
     */
    lookupOption(
      name: string,
      section_id?: string,
      config_name?: string,
    ): Array<LuCI.form.AbstractValue, string> | null;
    private checkDepends;
    private isDependencySatisfied;
  }
  class CBIAbstractSectionValue extends CBIAbstractValue {
    subsection: any;
    rows: number;
  }
  class CBIAbstractValue {
    __init__(map: any, section: any, option: any, ...args: any[]): void;
    section: any;
    option: any;
    map: any;
    config: any;
    deps: any[] | undefined;
    initial: Record<string, unknown> | undefined;
    rmempty: boolean | undefined;
    rawhtml: boolean | undefined;
    default: string | null | undefined;
    size: any;
    optional: boolean | undefined;
    modalonly: boolean | undefined;
    editable: boolean | undefined;
    retain: boolean | undefined;
    multiple: boolean | undefined;
    nocreate: boolean | undefined;
    password: boolean | undefined;
    allowlocal: boolean | undefined;
    datatype: string | undefined;
    placeholder: string | undefined;
    description: string | undefined;
    render(): Node;
    textvalue:
      | ((section_id: string) => HTMLElement)
      | ((section_id: string) => string);
    inputtitle(section_id: string);
    value(section_id: string, value: any): void;
    onclick(_ev: any, section_id: string);
    /**
     * If set to `false`, the underlying option value is retained upon saving
     * the form when the option element is disabled due to unsatisfied
     * dependency constraints.
     *
     * @name LuCI.form.AbstractValue.prototype#rmempty
     * @type boolean
     * @default true
     */
    /**
     * If set to `true`, the underlying ui input widget is allowed to be empty,
     * otherwise the option element is marked invalid when no value is entered
     * or selected by the user.
     *
     * @name LuCI.form.AbstractValue.prototype#optional
     * @type boolean
     * @default false
     */
    /**
     * If set to `true`, the underlying ui input widget value is not cleared
     * from the configuration on unsatisfied dependencies. The default behavior
     * is to remove the values of all options whose dependencies are not
     * fulfilled.
     *
     * @name LuCI.form.AbstractValue.prototype#retain
     * @type boolean
     * @default false
     */
    /**
     * Sets a default value to use when the underlying UCI option is not set.
     *
     * @name LuCI.form.AbstractValue.prototype#default
     * @type *
     * @default null
     */
    /**
     * Specifies a datatype constraint expression to validate input values
     * against. Refer to {@link LuCI.validation} for details on the format.
     *
     * If the user entered input does not match the datatype validation, the
     * option element is marked as invalid.
     *
     * @name LuCI.form.AbstractValue.prototype#datatype
     * @type string
     * @default null
     */
    /**
     * Specifies a custom validation function to test the user input for
     * validity. The validation function must return `true` to accept the
     * value. Any other return value type is converted to a string and
     * displayed to the user as a validation error message.
     *
     * If the user entered input does not pass the validation function, the
     * option element is marked as invalid.
     *
     * @name LuCI.form.AbstractValue.prototype#validate
     * @type function
     * @default null
     */
    /**
     * Override the UCI configuration name to read the option value from.
     *
     * By default, the configuration name is inherited from the parent Map.
     * By setting this property, a deviating configuration may be specified.
     *
     * The default of null means inherit from the parent form.
     *
     * @name LuCI.form.AbstractValue.prototype#uciconfig
     * @type string
     * @default null
     */
    /**
     * Override the UCI section name to read the option value from.
     *
     * By default, the section ID is inherited from the parent section element.
     * By setting this property, a deviating section may be specified.
     *
     * The default of null means inherit from the parent section.
     *
     * @name LuCI.form.AbstractValue.prototype#ucisection
     * @type string
     * @default null
     */
    /**
     * Override the UCI option name to read the value from.
     *
     * By default, the elements name, which is passed as the third argument to
     * the constructor, is used as the UCI option name. By setting this property,
     * a deviating UCI option may be specified.
     *
     * The default of null means use the option element name.
     *
     * @name LuCI.form.AbstractValue.prototype#ucioption
     * @type string
     * @default null
     */
    /**
     * Mark the grid section option element as editable.
     *
     * Options which are displayed in the table portion of a `GridSection`
     * instance are rendered as readonly text by default. By setting the
     * `editable` property of a child option element to `true`, that element
     * is rendered as a full input widget within its cell instead of a text only
     * preview.
     *
     * This property has no effect on options that are not children of grid
     * section elements.
     *
     * @name LuCI.form.AbstractValue.prototype#editable
     * @type boolean
     * @default false
     */
    /**
     * Move the grid section option element into the table, the modal popup or both.
     *
     * If this property is `null` (the default), the option element is
     * displayed in both the table preview area and the per-section instance
     * modal popup of a grid section. When it is set to `false` the option
     * is only shown in the table but not the modal popup. When set to `true`,
     * the option is only visible in the modal popup but not the table.
     *
     * This property has no effect on options that are not children of grid
     * section elements.
     *
     * @name LuCI.form.AbstractValue.prototype#modalonly
     * @type boolean
     * @default null
     */
    /**
     * Make option element readonly.
     *
     * This property defaults to the readonly state of the parent form element.
     * When set to `true`, the underlying widget is rendered in disabled state,
     * meaning its contents cannot be changed and the widget cannot be
     * interacted with.
     *
     * @name LuCI.form.AbstractValue.prototype#readonly
     * @type boolean
     * @default false
     */
    /**
     * Override the cell width of a table or grid section child option.
     *
     * If the property is set to a numeric value, it is treated as pixel width
     * which is set on the containing cell element of the option, essentially
     * forcing a certain column width. When the property is set to a string
     * value, it is applied as-is to the CSS `width` property.
     *
     * This property has no effect on options that are not children of grid or
     * table section elements.
     *
     * @name LuCI.form.AbstractValue.prototype#width
     * @type number|string
     * @default null
     */
    /**
     * Register a custom value change handler.
     *
     * If this property is set to a function, it is invoked
     * whenever the value of the underlying UI input element changes.
     *
     * The invoked handler function will receive the DOM click element as
     * first and the underlying configuration section ID as well as the input
     * value as second and third argument respectively.
     *
     * @name LuCI.form.AbstractValue.prototype#onchange
     * @type function
     * @default null
     */
    /**
     * Add a dependency constraint to the option.
     *
     * Dependency constraints allow making the presence of option elements
     * dependent on the current values of certain other options within the
     * same form. An option element with unsatisfied dependencies will be
     * hidden from the view and its current value omitted when saving.
     *
     * Multiple constraints (that is, multiple calls to `depends()`) are
     * treated as alternatives, forming a logical "or" expression.
     *
     * By passing an object of name => value pairs as the first argument, it is
     * possible to depend on multiple options simultaneously, forming
     * a logical "and" expression.
     *
     * Option names may be given in "dot notation" which allows referencing
     * option elements outside the current form section. If a name without
     * a dot is specified, it refers to an option within the same configuration
     * section. If specified as <code>configname.sectionid.optionname</code>,
     * options anywhere within the same form may be specified.
     *
     * The object notation also allows for a number of special keys which are
     * not treated as option names but as modifiers to influence the dependency
     * constraint evaluation. The associated value of these special "tag" keys
     * is ignored. The recognized tags are:
     *
     * <ul>
     *   <li>
     *	<code>!reverse</code><br>
     *	Invert the dependency, instead of requiring another option to be
     *	equal to the dependency value, that option should <em>not</em> be
     *	equal.
     *   </li>
     *   <li>
     *	<code>!contains</code><br>
     *	Instead of requiring an exact match, the dependency is considered
     *	satisfied when the dependency value is contained within the option
     *	value.
     *   </li>
     *   <li>
     *	<code>!default</code><br>
     *	The dependency is always satisfied
     *   </li>
     * </ul>
     *
     * Examples:
     *
     * <ul>
     *  <li>
     *   <code>opt.depends("foo", "test")</code><br>
     *   Require the value of `foo` to be `test`.
     *  </li>
     *  <li>
     *   <code>opt.depends({ foo: "test" })</code><br>
     *   Equivalent to the previous example.
     *  </li>
     *  <li>
     *   <code>opt.depends({ foo: /test/ })</code><br>
     *   Require the value of `foo` to match the regular expression `/test/`.
     *  </li>
     *  <li>
     *   <code>opt.depends({ foo: "test", bar: "qrx" })</code><br>
     *   Require the value of `foo` to be `test` and the value of `bar` to be
     *   `qrx`.
     *  </li>
     *  <li>
     *   <code>opt.depends({ foo: "test" })<br>
     *		 opt.depends({ bar: "qrx" })</code><br>
     *   Require either <code>foo</code> to be set to <code>test</code>,
     *   <em>or</em> the <code>bar</code> option to be <code>qrx</code>.
     *  </li>
     *  <li>
     *   <code>opt.depends("test.section1.foo", "bar")</code><br>
     *   Require the "foo" form option within the "section1" section to be
     *   set to "bar".
     *  </li>
     *  <li>
     *   <code>opt.depends({ foo: "test", "!contains": true })</code><br>
     *   Require the "foo" option value to contain the substring "test".
     *  </li>
     * </ul>
     *
     * @param {string|Object<string, string|RegExp>} field
     * The name of the option to depend on or an object describing multiple
     * dependencies which must be satisfied (a logical "and" expression).
     *
     * @param {string|RegExp} [value]
     * When invoked with a plain option name as the first argument, this parameter
     * specifies the expected value. In case an object is passed as the first
     * argument, this parameter is ignored.
     */
    depends(
      field:
        | string
        | {
            [x: string]: string | RegExp;
          },
      value?: string | RegExp,
    ): void;
    /** @private */
    private transformDepList;
    /** @private */
    private transformChoices;
    /** @private */
    private checkDepends;
    /** @private */
    private updateDefaultValue;
    /**
     * Obtain the internal ID ("cbid") of the element instance.
     *
     * Since each form section element may map multiple underlying
     * configuration sections, the configuration section ID is required to
     * form a fully qualified ID pointing to the specific element instance
     * within the given specific section.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception when no `section_id` was specified.
     *
     * @returns {string}
     * Returns the element ID.
     */
    cbid(section_id: string): string;
    /**
     * Load the underlying configuration value.
     *
     * The default implementation of this method reads and returns the
     * underlying UCI option value (or the related JavaScript property for
     * `JSONMap` instances). It may be overridden by user code to load data
     * from non-standard sources.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception when no `section_id` was specified.
     *
     * @returns {*|Promise<*>}
     * Returns the configuration value to initialize the option element with.
     * The return value of this function is filtered through `Promise.resolve()`
     * so it may return promises if overridden by user code.
     */
    load(section_id: string): any | Promise<any>;
    /**
     * Obtain the underlying `LuCI.ui` element instance.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception when no `section_id` was specified.
     *
     * @return {LuCI.ui.AbstractElement|null}
     * Returns the `LuCI.ui` element instance or `null` in case the form
     * option implementation does not use `LuCI.ui` widgets.
     */
    getUIElement(section_id: string): LuCI.ui.AbstractElement | null;
    /**
     * Query the underlying configuration value.
     *
     * The default implementation of this method returns the cached return
     * value of [load()]{@link LuCI.form.AbstractValue#load}. It may be
     * overridden by user code to obtain the configuration value in a
     * different way.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception when no `section_id` was specified.
     *
     * @returns {*}
     * Returns the configuration value.
     */
    cfgvalue(section_id: string, set_value: any, ...args: any[]): any;
    /**
     * Query the current form input value.
     *
     * The default implementation of this method returns the current input
     * value of the underlying [LuCI.ui]{@link LuCI.ui.AbstractElement} widget.
     * It may be overridden by user code to handle input values differently.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception when no `section_id` was specified.
     *
     * @returns {*}
     * Returns the current input value.
     */
    formvalue(section_id: string): any;
    /**
     * Obtain a textual input representation.
     *
     * The default implementation of this method returns the HTML-escaped
     * current input value of the underlying
     * [LuCI.ui]{@link LuCI.ui.AbstractElement} widget. User code or specific
     * option element implementations may override this function to apply a
     * different logic, e.g. to return `Yes` or `No` depending on the checked
     * state of checkbox elements.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @throws {TypeError}
     * Throws a `TypeError` exception when no `section_id` was specified.
     *
     * @returns {string}
     * Returns the text representation of the current input value.
     */
    textvalue(section_id: string): string;
    /**
     * Apply custom validation logic.
     *
     * This method is invoked whenever incremental validation is performed on
     * the user input, e.g. on keyup or blur events.
     *
     * The default implementation of this method does nothing and always
     * returns `true`. User code may override this method to provide
     * additional validation logic which is not covered by data type
     * constraints.
     *
     * @abstract
     * @param {string} section_id
     * The configuration section ID
     *
     * @param {*} value
     * The value to validate
     *
     * @returns {*}
     * The method shall return `true` to accept the given value. Any other
     * return value is treated as a failure, converted to a string and displayed
     * as an error message to the user.
     */
    validate(section_id: string, value: any): any;
    /**
     * Test whether the input value is currently valid.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @returns {boolean}
     * Returns `true` if the input value currently is valid, otherwise it
     * returns `false`.
     */
    isValid(section_id: string): boolean;
    /**
     * Returns the current validation error for this input.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @returns {string}
     * The validation error at this time
     */
    getValidationError(section_id: string): string;
    /**
     * Test whether the option element is currently active.
     *
     * An element is active when it is not hidden due to unsatisfied dependency
     * constraints.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @returns {boolean}
     * Returns `true` if the option element currently is active, otherwise it
     * returns `false`.
     */
    isActive(section_id: string): boolean;
    /** @private */
    private setActive;
    /** @private */
    private triggerValidation;
    /**
     * Parse the option element input.
     *
     * The function is invoked when the `parse()` method has been invoked on
     * the parent form and triggers input value reading and validation.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @returns {Promise<void>}
     * Returns a promise resolving once the input value has been read and
     * validated or rejecting in case the input value does not meet the
     * validation constraints.
     */
    parse(section_id: string): Promise<void>;
    /**
     * Write the current input value into the configuration.
     *
     * This function is invoked upon saving the parent form when the option
     * element is valid and when its input value has been changed compared to
     * the initial value returned by
     * [cfgvalue()]{@link LuCI.form.AbstractValue#cfgvalue}.
     *
     * The default implementation simply sets the given input value in the
     * UCI configuration (or the associated JavaScript object property in
     * case of `JSONMap` forms). It may be overridden by user code to
     * implement alternative save logic, e.g. to transform the input value
     * before it is written.
     *
     * @param {string} section_id
     * The configuration section ID
     *
     * @param {string|string[]}	formvalue
     * The input value to write.
     */
    write(section_id: string, formvalue: string | string[]): any;
    /**
     * Remove the corresponding value from the configuration.
     *
     * This function is invoked upon saving the parent form when the option
     * element has been hidden due to unsatisfied dependencies or when the
     * user cleared the input value and the option is marked optional.
     *
     * The default implementation simply removes the associated option from the
     * UCI configuration (or the associated JavaScript object property in
     * case of `JSONMap` forms). It may be overridden by user code to
     * implement alternative removal logic, e.g. to retain the original value.
     *
     * @param {string} section_id
     * The configuration section ID
     */
    remove(section_id: string): void;
  }

  class CBIValue extends CBIAbstractValue {
    /**
     * If set to `true`, the field is rendered as a password input, otherwise
     * as a plain text input.
     *
     * @name LuCI.form.Value.prototype#password
     * @type boolean
     * @default false
     */
    /**
     * Set a placeholder string to use when the input field is empty.
     *
     * @name LuCI.form.Value.prototype#placeholder
     * @type string
     * @default null
     */
    /**
     * Add a predefined choice to the form option. By adding one or more
     * choices, the plain text input field is turned into a combobox widget
     * which prompts the user to select a predefined choice, or to enter a
     * custom value.
     *
     * @param {string} key
     * The choice value to add.
     *
     * @param {Node|string} val
     * The caption for the choice value. May be a DOM node, a document fragment
     * or a plain text string. If omitted, the `key` value is used as a caption.
     */
    value(key: string, val: Node | string): void;
    render(option_index: any, section_id: any, in_table: any): Promise<any>;
    handleValueChange(section_id: any, state: any, ev: any): void;
    renderFrame(
      section_id: any,
      in_table: any,
      option_index: any,
      nodes: any,
    ): any;
    renderWidget(section_id: any, option_index: any, cfgvalue: any): any;
  }
}
