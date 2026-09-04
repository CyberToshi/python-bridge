"""AST-based function signature analysis.

Analyzes a Python source file WITHOUT executing it and returns a JSON-safe
schema of its top-level functions. This is the basis for the GDScript
wrapper generator (editor/wrapper_generator.gd).

Returned schema (deterministic, source order):
  {
    "functions": [
      {
        "name": str,
        "kind": "def" | "async_def",
        "docstring": str,
        "returns": str,                      # annotation source or ""
        "params": [
          {
            "name": str,
            "kind": "posonly"|"pos"|"var"|"kwonly"|"kw",
            "has_default": bool,
            "default": str,                  # repr of the default ("" if none)
            "annotation": str,               # annotation source or ""
          }
        ]
      }
    ]
  }

Type hints are treated as hints only (never as runtime guarantees); the
wrapper generator therefore exposes them as documentation, not as static
types. Any other top-level node (imports, assignments, classes) is ignored
for wrapper purposes.
"""

import ast


def analyze(source):
    tree = ast.parse(source)
    functions = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions.append(_function_schema(node))
    return {"functions": functions}


def _function_schema(node):
    args = node.args
    params = []

    def add(name, kind, has_default=False, default=None, annotation=None):
        params.append({
            "name": name,
            "kind": kind,
            "has_default": bool(has_default),
            "default": _repr(default) if has_default else "",
            "annotation": _unparse(annotation),
        })

    # Positional-only:  def f(a, b, /, c)
    for i, a in enumerate(args.posonlyargs):
        has_def = i >= len(args.posonlyargs) - len(args.defaults)
        default = args.defaults[i - (len(args.posonlyargs) - len(args.defaults))] \
            if has_def else None
        add(a.arg, "posonly", has_def, default, a.annotation)

    # Positional-or-keyword
    ndefaults = len(args.defaults)
    npos = len(args.args)
    start = npos - ndefaults if ndefaults > 0 else npos
    for i, a in enumerate(args.args):
        has_def = i >= start
        default = args.defaults[i - start] if has_def else None
        add(a.arg, "pos", has_def, default, a.annotation)

    if args.vararg:
        add(args.vararg.arg, "var", annotation=args.vararg.annotation)

    # Keyword-only:  def f(*, a, b)
    kw_defaults = args.kw_defaults
    for i, a in enumerate(args.kwonlyargs):
        d = kw_defaults[i] if i < len(kw_defaults) else None
        add(a.arg, "kwonly", d is not None, d, a.annotation)

    if args.kwarg:
        add(args.kwarg.arg, "kw", annotation=args.kwarg.annotation)

    return {
        "name": node.name,
        "kind": "async_def" if isinstance(node, ast.AsyncFunctionDef) else "def",
        "docstring": _docstring(node),
        "returns": _unparse(node.returns),
        "params": params,
    }


def _docstring(node):
    try:
        doc = ast.get_docstring(node, clean=False)
    except TypeError:  # very old ast versions without clean param
        doc = ast.get_docstring(node)
    return doc or ""


def _unparse(node):
    if node is None:
        return ""
    try:
        return ast.unparse(node).strip()
    except Exception:  # pragma: no cover - ast.unparse is stable on 3.9+
        return ""


def _repr(node):
    """Stringifies an AST default node (e.g. Constant(2) -> "2")."""
    if node is None:
        return ""
    try:
        return ast.unparse(node).strip()
    except Exception:  # pragma: no cover
        return ""