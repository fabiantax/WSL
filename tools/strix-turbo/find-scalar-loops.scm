; Tree-sitter query to find scalar loops iterating over strings for path separators
; Target: C++ code in WSL Plan9 filesystem for AVX-512 SIMD optimization
;
; Usage: tree-sitter query find-scalar-loops.scm <source-files>

;; ============================================================================
;; Pattern 1: while loop with pointer dereference and increment
;; Matches: while (*p && *p != '/' && *p != '\\') p++;
;; Matches: while (*ptr) { if (*ptr == '/') break; ptr++; }
;; ============================================================================

(while_statement
  condition: [
    ; while (*p && *p != '/')
    (binary_expression
      left: (_) @condition_left
      right: (binary_expression
        left: (pointer_expression) @deref
        operator: "!="
        right: (char_literal) @separator))

    ; while (*p != '/' && *p != '\\')
    (binary_expression
      left: (binary_expression
        left: (pointer_expression) @deref
        operator: "!="
        right: (char_literal) @separator1)
      operator: "&&"
      right: (binary_expression
        left: (pointer_expression)
        operator: "!="
        right: (char_literal) @separator2))

    ; while (*p)
    (pointer_expression) @deref_simple
  ]
  body: [
    ; Single statement body: p++;
    (update_expression
      argument: (identifier) @ptr_var
      operator: "++") @ptr_increment

    ; Compound statement body
    (compound_statement) @loop_body
  ]) @while_loop_ptr_pattern

;; ============================================================================
;; Pattern 2: while loop with explicit null check and separator comparison
;; Matches: while (p && *p != '/') { p++; }
;; Matches: while (*p && (*p == '/' || *p == '\\')) p++;
;; ============================================================================

(while_statement
  condition: (binary_expression
    operator: "&&"
    left: [
      (identifier) @ptr_check
      (pointer_expression) @deref_check
    ]
    right: [
      (binary_expression
        left: (pointer_expression
          (identifier) @ptr_var)
        operator: ["!=" "=="]
        right: (char_literal) @separator)

      (parenthesized_expression
        (binary_expression
          operator: "||"
          left: (binary_expression
            left: (pointer_expression) @deref1
            operator: "=="
            right: (char_literal) @sep1)
          right: (binary_expression
            left: (pointer_expression) @deref2
            operator: "=="
            right: (char_literal) @sep2)))
    ])
  body: (_) @while_body) @while_loop_explicit_check

;; ============================================================================
;; Pattern 3: for loop with index-based string access
;; Matches: for (size_t i = 0; i < str.length(); i++) { if (str[i] == '/') ... }
;; Matches: for (int i = 0; i < len; i++) { if (s[i] == '/' || s[i] == '\\') ... }
;; ============================================================================

(for_statement
  initializer: (declaration
    declarator: (init_declarator
      declarator: (identifier) @index_var
      value: (number_literal) @init_zero))

  condition: (binary_expression
    left: (identifier) @index_check
    operator: "<"
    right: [
      ; str.length() or str.size()
      (call_expression
        function: (field_expression
          argument: (identifier) @string_var
          field: (field_identifier) @length_method))

      ; len or similar variable
      (identifier) @length_var

      ; strlen(str)
      (call_expression
        function: (identifier) @strlen_func
        arguments: (argument_list))
    ])

  update: [
    (update_expression
      argument: (identifier) @index_increment
      operator: ["++"])
    (assignment_expression
      left: (identifier) @index_assign
      right: (_))
  ]

  body: (compound_statement
    [
      ; if (str[i] == '/')
      (if_statement
        condition: [
          (binary_expression
            left: (subscript_expression
              argument: (identifier) @subscript_var
              index: (identifier) @subscript_index)
            operator: ["==" "!="]
            right: (char_literal) @char_sep)

          ; if (str[i] == '/' || str[i] == '\\')
          (binary_expression
            operator: "||"
            left: (binary_expression
              left: (subscript_expression) @subscript1
              operator: "=="
              right: (char_literal) @sep_char1)
            right: (binary_expression
              left: (subscript_expression) @subscript2
              operator: "=="
              right: (char_literal) @sep_char2))

          (parenthesized_expression
            (binary_expression) @paren_cond)
        ]) @char_check_if
    ] @body_content)) @for_loop_index_pattern

;; ============================================================================
;; Pattern 4: for loop with iterator/pointer arithmetic
;; Matches: for (char* p = str; *p; p++) { if (*p == '/') ... }
;; Matches: for (const char* p = start; p < end; p++) { if (*p == '/') ... }
;; ============================================================================

(for_statement
  initializer: (declaration
    type: (_) @ptr_type
    declarator: (init_declarator
      declarator: [
        (pointer_declarator
          declarator: (identifier) @ptr_var_name)
        (identifier) @ptr_var_direct
      ]
      value: (_) @ptr_init))

  condition: [
    ; *p or *p != 0
    (pointer_expression
      (identifier) @ptr_cond_var)

    (binary_expression
      left: [
        (pointer_expression) @deref_cond
        (identifier) @ptr_var_cond
      ]
      operator: ["!=" "<" "<="]
      right: (_) @cond_right)
  ]

  update: (update_expression
    argument: (identifier) @ptr_update_var
    operator: "++")

  body: (compound_statement) @ptr_loop_body) @for_loop_ptr_pattern

;; ============================================================================
;; Pattern 5: Loops with strchr or memchr calls
;; Matches: while ((p = strchr(p, '/')) != nullptr) { ... }
;; Matches: if (char* sep = strchr(path, '/')) { ... }
;; ============================================================================

(while_statement
  condition: (binary_expression
    left: [
      (assignment_expression
        left: (identifier) @strchr_result
        right: (call_expression
          function: (identifier) @strchr_func
          arguments: (argument_list
            (identifier) @strchr_input
            (char_literal) @strchr_sep)))

      (call_expression
        function: (identifier) @memchr_func
        arguments: (argument_list))
    ]
    operator: "!="
    right: [
      (nullptr)
      (null)
      (number_literal) @null_zero
    ])) @strchr_while_loop

;; ============================================================================
;; Pattern 6: do-while loops with character scanning
;; Matches: do { p++; } while (*p && *p != '/');
;; ============================================================================

(do_statement
  body: (compound_statement
    [
      (expression_statement
        (update_expression
          argument: (identifier) @do_ptr_var
          operator: "++"))
      (expression_statement
        (assignment_expression
          left: (identifier) @do_assign_var))
    ] @do_body_stmt)

  condition: [
    (binary_expression
      operator: "&&"
      left: (pointer_expression) @do_deref_left
      right: (binary_expression
        left: (pointer_expression) @do_deref_right
        operator: "!="
        right: (char_literal) @do_separator))

    (binary_expression
      left: (pointer_expression) @do_simple_deref
      operator: "!="
      right: (char_literal) @do_sep)
  ]) @do_while_loop_pattern

;; ============================================================================
;; Pattern 7: Inline conditions with pointer increment
;; Matches: if (*p == '/') p++; else if (*p == '\\') p++;
;; Matches: while (condition) { if (*p == '/') found = true; p++; }
;; ============================================================================

(if_statement
  condition: [
    (binary_expression
      left: (pointer_expression
        (identifier) @if_ptr_var)
      operator: ["==" "!="]
      right: (char_literal) @if_separator)

    (parenthesized_expression
      (binary_expression) @if_paren_cond)
  ]
  consequence: [
    ; p++;
    (expression_statement
      (update_expression
        argument: (identifier) @if_consequence_ptr
        operator: "++"))

    (compound_statement
      (expression_statement
        (update_expression
          argument: (identifier) @if_block_ptr
          operator: "++"))) @if_consequence_block
  ]) @if_ptr_increment_pattern

;; ============================================================================
;; Pattern 8: Range-based for loop over string with character comparison
;; Matches: for (char c : str) { if (c == '/' || c == '\\') ... }
;; Matches: for (auto ch : path) { if (ch == '/') ... }
;; ============================================================================

(for_range_loop
  declarator: (reference_declarator
    (identifier) @range_var)
  right: (identifier) @range_string
  body: (compound_statement
    (if_statement
      condition: [
        (binary_expression
          left: (identifier) @range_char_var
          operator: ["==" "!="]
          right: (char_literal) @range_separator)

        (binary_expression
          operator: "||"
          left: (binary_expression
            left: (identifier) @range_char1
            operator: "=="
            right: (char_literal) @range_sep1)
          right: (binary_expression
            left: (identifier) @range_char2
            operator: "=="
            right: (char_literal) @range_sep2))
      ]))) @range_for_loop_pattern

;; Alternative range-based for without reference
(for_range_loop
  declarator: (identifier) @range_simple_var
  right: (identifier) @range_simple_string
  body: (compound_statement
    (if_statement
      condition: (binary_expression
        left: (identifier) @range_simple_char
        operator: ["==" "!="]
        right: (char_literal) @range_simple_sep)))) @range_simple_for_loop

;; ============================================================================
;; Pattern 9: Loop with find_first_of or find_last_of (std::string methods)
;; Matches: size_t pos = str.find_first_of("/\\");
;; Matches: while ((pos = str.find('/', pos)) != std::string::npos) { ... }
;; ============================================================================

(expression_statement
  (assignment_expression
    left: (identifier) @find_result
    right: (call_expression
      function: (field_expression
        argument: (identifier) @find_string
        field: (field_identifier) @find_method
        (#match? @find_method "find.*"))
      arguments: (argument_list
        [
          (string_literal) @find_chars
          (char_literal) @find_char
        ])))) @find_expression

;; ============================================================================
;; Pattern 10: Loop incrementing through buffer with size check
;; Matches: for (size_t i = 0; i < size; i++) { if (buffer[i] == '/' || buffer[i] == '\\') ... }
;; ============================================================================

(for_statement
  initializer: (declaration
    declarator: (init_declarator
      declarator: (identifier) @buf_index_var
      value: (number_literal "0")))

  condition: (binary_expression
    left: (identifier) @buf_index_check
    operator: "<"
    right: [
      (identifier) @buf_size_var
      (field_expression
        argument: (identifier) @buf_obj
        field: (field_identifier) @buf_size_field)
    ])

  update: (update_expression
    argument: (identifier) @buf_index_update
    operator: "++")

  body: (compound_statement
    (if_statement
      condition: (binary_expression
        left: (subscript_expression
          argument: (identifier) @buf_var
          index: (identifier) @buf_idx)
        operator: ["==" "!="]
        right: (char_literal
          (#match? @char_literal "^'[\\/\\\\]'$")))))) @buffer_scan_loop

;; ============================================================================
;; Pattern 11: Nested separator checks (both forward and back slash)
;; Matches: if (c == '/' || c == '\\') { ... }
;; This can appear within any loop body
;; ============================================================================

(binary_expression
  operator: "||"
  left: (binary_expression
    left: [
      (pointer_expression
        (identifier) @dual_sep_ptr)
      (identifier) @dual_sep_var
      (subscript_expression
        argument: (identifier) @dual_sep_array
        index: (_) @dual_sep_index)
    ]
    operator: "=="
    right: (char_literal
      (#match? @char_literal "^'[\\/]'$")) @dual_sep_char1)
  right: (binary_expression
    left: [
      (pointer_expression)
      (identifier)
      (subscript_expression)
    ]
    operator: "=="
    right: (char_literal
      (#match? @char_literal "^'[\\/\\\\]'$")) @dual_sep_char2)) @dual_separator_check

;; ============================================================================
;; Pattern 12: Switch statement on character with path separator cases
;; Matches: switch (*p) { case '/': case '\\': ... }
;; ============================================================================

(switch_statement
  condition: (condition_clause
    [
      (pointer_expression
        (identifier) @switch_ptr)
      (subscript_expression
        argument: (identifier) @switch_array
        index: (_) @switch_index)
      (identifier) @switch_var
    ])
  body: (compound_statement
    (case_statement
      value: (char_literal
        (#match? @char_literal "^'[\\/\\\\]'$")) @case_separator))) @switch_char_pattern

;; ============================================================================
;; Pattern 13: Ternary with separator check
;; Matches: char c = (*p == '/' || *p == '\\') ? ... : ...;
;; ============================================================================

(conditional_expression
  condition: [
    (binary_expression
      left: [
        (pointer_expression) @ternary_deref
        (subscript_expression) @ternary_subscript
        (identifier) @ternary_var
      ]
      operator: "=="
      right: (char_literal
        (#match? @char_literal "^'[\\/\\\\]'$")))

    (binary_expression
      operator: "||"
      left: (binary_expression
        left: (_) @ternary_left_var
        operator: "=="
        right: (char_literal) @ternary_sep1)
      right: (binary_expression
        left: (_) @ternary_right_var
        operator: "=="
        right: (char_literal) @ternary_sep2))
  ]) @ternary_separator_check

;; ============================================================================
;; Pattern 14: std::find or std::find_if with lambda checking for separators
;; Matches: auto it = std::find(begin, end, '/');
;; Matches: std::find_if(str.begin(), str.end(), [](char c) { return c == '/'; });
;; ============================================================================

(call_expression
  function: [
    (qualified_identifier
      scope: (namespace_identifier) @std_namespace
      name: (identifier) @std_find_func
      (#match? @std_find_func "^find.*$"))
    (identifier) @find_func
    (#match? @find_func "^find.*$")
  ]
  arguments: (argument_list
    [
      ; std::find(begin, end, '/')
      (char_literal
        (#match? @char_literal "^'[\\/\\\\]'$"))

      ; std::find_if with lambda
      (lambda_expression
        body: (compound_statement
          (return_statement
            (binary_expression
              operator: "=="
              right: (char_literal
                (#match? @char_literal "^'[\\/\\\\]'$"))))))
    ])) @std_find_call

;; ============================================================================
;; Pattern 15: Manual strchr/memchr implementation patterns
;; Matches: while (*p) { if (*p == '/') return p; p++; }
;; ============================================================================

(while_statement
  condition: (pointer_expression
    (identifier) @manual_scan_ptr)
  body: (compound_statement
    [
      (if_statement
        condition: (binary_expression
          left: (pointer_expression
            (identifier) @manual_if_ptr)
          operator: "=="
          right: (char_literal) @manual_sep))
        consequence: (return_statement) @manual_return)

      (expression_statement
        (update_expression
          argument: (identifier) @manual_increment_ptr
          operator: "++"))
    ])) @manual_strchr_pattern
