Values can now be quoted. A value that starts with `"` runs to the closing `"`: whitespace
inside the quotes is kept, and `\"` and `\\` stand for a quote and a backslash. Only whitespace
may follow the closing quote. A missing closing quote, any other backslash escape, and text
after the closing quote are errors that name the line, like the existing ones. Values that do
not start with a quote work as before. Include tests.
