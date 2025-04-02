/*-
 * Copyright (c) 2017-2018 elementary LLC. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

public class Scratch.Services.ValaSymbolOutline : Scratch.Services.SymbolOutline {
    public const int PARSE_TIME_MAX_MSEC = 1000;
    private Code.Plugins.ValaSymbolResolver resolver;
    private Vala.Parser parser;
    private GLib.Cancellable cancellable;
    public ValaSymbolOutline (Scratch.Services.Document _doc) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true,
            doc: _doc
        );
    }

    static construct {
        // Array of symbol types that could be assigned to a ValaSymbolItem
        // by construct_child output ()
        filters = {
            SymbolType.CLASS,
            SymbolType.CONSTRUCTOR,
            SymbolType.PROPERTY,
            SymbolType.METHOD,
            SymbolType.STRUCT,
            SymbolType.ENUM,
            SymbolType.CONSTANT,
            SymbolType.INTERFACE
        };
    }

    construct {
        parser = new Vala.Parser ();
        resolver = new Code.Plugins.ValaSymbolResolver ();

        store.item_selected.connect ((selected) => {
            if (selected == null) {
                return;
            }

            doc.goto (((ValaSymbolItem)selected).symbol.source_reference.begin.line);
            store.selected = null;
        });

        doc.doc_closed.connect (doc_closed);
    }

    ~ValaSymbolOutline () {
        debug ("Destroy symbol out line");
    }

    void doc_closed (Scratch.Services.Document doc) {
        doc.doc_closed.disconnect (doc_closed);
        if (cancellable != null) {
            cancellable.cancel ();
            cancellable = null;
        }
    }

    private uint parse_timeout_id = 0;
    public override void parse_symbols () {
        tool_box_sensitive = true;
        var context = new Vala.CodeContext ();
#if VALA_0_50
        context.set_target_profile (Vala.Profile.GOBJECT, false);
#else
        context.profile = Vala.Profile.GOBJECT;
#endif
        context.add_source_filename (doc.file.get_path ());
        context.report = new Report ();
        if (cancellable != null && !cancellable.is_cancelled ()) {
            cancellable.cancel ();
        }

        cancellable = new GLib.Cancellable ();
        new Thread<void*> ("parse-symbols", () => {
            Vala.CodeContext.push (context);
            parser.parse (context);
            resolver.clear ();
            resolver.resolve (context);
            Vala.CodeContext.pop ();

            bool took_too_long = false;
            parse_timeout_id = Timeout.add_full (Priority.LOW, PARSE_TIME_MAX_MSEC, () => {
                parse_timeout_id = 0;
                took_too_long = true;
                cancellable.cancel ();
                return Source.REMOVE;
            });

            var new_root = construct_tree (cancellable);
            if (parse_timeout_id > 0) {
                Source.remove (parse_timeout_id);
            }

            if (!cancellable.is_cancelled () || took_too_long) {
                Idle.add (() => {
                    double adjustment_value = store.vadjustment.value;
                    var root_children = store.root.children; // Keep reference to children for later destruction
                    store.root.clear (); // This does not destroy children but disconnects signals - avoids terminal warnings
                    foreach (var child in root_children) { // Destroy items after clearing list to avoid memory leak
                        destroy_all_children ((Code.Widgets.SourceList.ExpandableItem)child);
                    }

                    if (took_too_long) {
                        var warning_item = new Code.Widgets.SourceList.Item () {
                            icon = new ThemedIcon ("dialog-warning"),
                            markup = "<big>%s</big>".printf (_("Too Many Symbols")),
                            tooltip = _("%s contains too many Vala symbols.\nParsing and showing them took long").printf (doc.file.get_basename ()),
                            selectable = false
                        };

                        store.root.add (warning_item);
                        tool_box_sensitive = false;

                    } else {
                        store.root.add (new_root);
                    }

                    store.root.expand_all ();
                    store.vadjustment.set_value (adjustment_value);

                    return false;
                });
            } else {
                destroy_all_children (new_root);
            }

            return null;
        });
    }

    private void destroy_all_children (Code.Widgets.SourceList.ExpandableItem parent) {
        foreach (var child in parent.children) {
            remove (child, parent);
        }
    }

    private new void remove (Code.Widgets.SourceList.Item item, Code.Widgets.SourceList.ExpandableItem parent) {
        if (item is Code.Widgets.SourceList.ExpandableItem) {
            destroy_all_children ((Code.Widgets.SourceList.ExpandableItem)item);
        }

        parent.remove (item);
    }

    private Code.Widgets.SourceList.ExpandableItem construct_tree (GLib.Cancellable cancellable) {
        var fields = resolver.get_properties_fields ();
        var symbols = resolver.get_symbols ();
        // Remove fake fields created by the vala parser.
        symbols.remove_all (fields);

        var new_root = new Code.Widgets.SourceList.ExpandableItem (_("Symbols"));
        foreach (var symbol in symbols) {
            if (cancellable.is_cancelled ())
                break;


            if (symbol.name == null)
                continue;

            construct_child (symbol, new_root, cancellable);
        }

        return new_root;
    }

    private ValaSymbolItem construct_child (Vala.Symbol symbol, Code.Widgets.SourceList.ExpandableItem given_parent, GLib.Cancellable cancellable) {
        Code.Widgets.SourceList.ExpandableItem parent;
        if (symbol.scope.parent_scope.owner.name == null)
            parent = given_parent;
        else
            parent = find_existing (symbol.scope.parent_scope.owner, given_parent, cancellable);

        if (parent == null) {
            parent = construct_child (symbol.scope.parent_scope.owner, given_parent, cancellable);
        }

        var tree_child = new ValaSymbolItem (symbol);
        if (symbol is Vala.Struct) {
            tree_child.icon = new ThemedIcon ("lang-struct");
            tree_child.symbol_type = SymbolType.STRUCT;
        } else if (symbol is Vala.Class) {
            if (((Vala.Class) symbol).is_abstract) {
                tree_child.icon = new ThemedIcon ("lang-class-abstract");
            } else {
                tree_child.icon = new ThemedIcon ("lang-class");
            }

            tree_child.symbol_type = SymbolType.CLASS;
        } else if (symbol is Vala.Constant) {
            tree_child.icon = new ThemedIcon ("lang-constant");
            tree_child.symbol_type = SymbolType.CONSTANT;
        } else if (symbol is Vala.Enum) {
            tree_child.icon = new ThemedIcon ("lang-enum");
            tree_child.symbol_type = SymbolType.ENUM;
        } else if (symbol is Vala.Field) {
            tree_child.icon = new ThemedIcon ("lang-property");
            tree_child.symbol_type = SymbolType.PROPERTY;
        } else if (symbol is Vala.Interface) {
            tree_child.icon = new ThemedIcon ("lang-interface");
            tree_child.symbol_type = SymbolType.INTERFACE;
        } else if (symbol is Vala.Property) {
            if (((Vala.Property) symbol).is_abstract) {
                tree_child.icon = new ThemedIcon ("lang-property-abstract");
            } else if (((Vala.Property) symbol).is_virtual) {
                tree_child.icon = new ThemedIcon ("lang-property-virtual");
            } else {
                tree_child.icon = new ThemedIcon ("lang-property");
            }

            tree_child.symbol_type = SymbolType.PROPERTY;
        } else if (symbol is Vala.Signal) {
            tree_child.icon = new ThemedIcon ("lang-signal");
            tree_child.symbol_type = SymbolType.SIGNAL;
        } else if (symbol is Vala.CreationMethod) {
            tree_child.icon = new ThemedIcon ("lang-constructor");
            tree_child.symbol_type = SymbolType.CONSTRUCTOR;
        } else if (symbol is Vala.Method) {
            if (((Vala.Method) symbol).is_abstract) {
                tree_child.icon = new ThemedIcon ("lang-method-abstract");
            } else if (((Vala.Method) symbol).is_virtual) {
                tree_child.icon = new ThemedIcon ("lang-method-virtual");
            } else if (((Vala.Method) symbol).binding == Vala.MemberBinding.STATIC) {
                tree_child.icon = new ThemedIcon ("lang-method-static");
            } else {
                tree_child.icon = new ThemedIcon ("lang-method");
            }

            tree_child.symbol_type = SymbolType.METHOD;
        } else if (symbol is Vala.Namespace) {
            tree_child.icon = new ThemedIcon ("lang-namespace");
            tree_child.symbol_type = SymbolType.NAMESPACE;
        } else if (symbol is Vala.ErrorDomain) {
            tree_child.icon = new ThemedIcon ("lang-errordomain");
        } else if (symbol is Vala.Delegate) {
            tree_child.icon = new ThemedIcon ("lang-delegate");
        } else {
            warning (symbol.type_name);
        }

        parent.add (tree_child);
        return tree_child;
    }

    ValaSymbolItem? find_existing (Vala.Symbol symbol, Code.Widgets.SourceList.ExpandableItem parent, GLib.Cancellable cancellable) {
        ValaSymbolItem match = null;
        foreach (var _child in parent.children) {
            if (cancellable.is_cancelled ())
                break;

            var child = _child as ValaSymbolItem;
            if (child == null)
                continue;

            if (child.symbol == symbol) {
                match = child;
                break;
            } else {
                var res = find_existing (symbol, child, cancellable);
                if (res != null)
                    return res;
            }
        }

        return match;
    }
}

public class Report : Vala.Report {
    // just mute everything
    public override void err (Vala.SourceReference? ref, string msg) {}
    public override void warn (Vala.SourceReference? ref, string msg) {}
    public override void note (Vala.SourceReference? ref, string msg) {}
    public override void depr (Vala.SourceReference? ref, string msg) {}
}
