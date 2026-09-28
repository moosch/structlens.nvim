; Records that actually define a body. `struct Foo;` and `struct Foo x;` have no layout to annotate and are deliberately excluded.
(struct_specifier body: (field_declaration_list)) @record
(union_specifier  body: (field_declaration_list)) @record
