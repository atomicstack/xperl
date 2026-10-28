#ifndef PERL_DIAGPACK_H
#define PERL_DIAGPACK_H

typedef struct {
    const char *name;
    U8 index;
    U16 domain_id;
    const char * const *values;
    U16 value_count;
    U8 value_width;
    U8 shift;
    const char *plural_kind;
    bool assert_unknown;
    bool operation_word;
    IV (*plural_form)(pTHX_ U16 language, UV n);
    bool native_id;
} perl_diag_selector_t;

typedef struct {
    const char *name;
    const char *type;
} perl_diagpack_param_schema_t;

typedef struct {
    UV diagnostic_number;
    const char *code;
    const U16 *param_ids;
    U8 param_count;
} perl_diagpack_schema_t;

typedef struct {
    UV diagnostic_number;
    U64 selector_pattern;
    const char *positional_template;
    U8 arg_count;
    U32 argument_index_offset;
} perl_diag_template_case_t;

/* Shared catalog rows used by the in-core renderer and XS language packs. */
typedef struct {
    const char *text;
    U64 selector_key;
} perl_diag_word_value_t;

typedef struct {
    const char * const *values;
    U16 value_count;
} perl_diag_selector_domain_t;

typedef struct {
    U8 source;
    U8 target;
    bool numeric;
    bool assert_unknown;
    U16 map_count;
    const U16 *map;
    const perl_diag_word_value_t *values;
    U64 selector_mask;
} perl_diag_word_binding_t;

typedef struct {
    U8 word_count;
    const perl_diag_word_binding_t *words;
} perl_diag_word_group_t;

typedef struct {
    U8 selector_count;
    U8 stored_param_count;
    U16 word_group;
    UV first_case;
    const perl_diag_selector_t *selectors;
} perl_diag_template_t;

typedef struct {
    const char *language;
    U16 language_id;
    const perl_diag_template_case_t *cases;
    U32 case_count;
    const U8 *argument_indices;
    U32 argument_index_count;
    const perl_diag_template_t *templates;
    U32 template_count;
    const perl_diagpack_schema_t * const *schemas;
    const perl_diagpack_param_schema_t *param_table;
    U32 param_table_count;
    const char * const *operation_names;
    U32 operation_count;
    const perl_diag_word_group_t *word_groups;
    U32 word_group_count;
} perl_diagpack_catalog;

typedef struct {
    SV *value;
} perl_diagpack_param;

struct perl_diagpack_input {
    UV diagnostic_number;
    Size_t param_count;
    const perl_diagpack_param *params;
    AV *arguments;
};

struct perl_diagpack_engine {
    U32 abi_version;
    U32 struct_size;
    const char *language;
    const perl_diagpack_catalog *catalog;
    SV *(*render)(pTHX_ const perl_diagpack_engine *, const perl_diagpack_input *);
    U8 (*cardinal)(pTHX_ UV n);
    U8 (*ordinal)(pTHX_ UV n);
};

#define PERL_DIAGPACK_ABI 5
#define PERL_DIAGPACK_HINT_KEY "XPerl::DiagPack/engine"

#endif /* PERL_DIAGPACK_H */
