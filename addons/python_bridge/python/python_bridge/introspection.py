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
import re


def analyze(source):
    tree = ast.parse(source)
    functions = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions.append(_function_schema(node))
    return {"functions": functions, "dependencies": deps_from_source(source)}


# one top-level assignment:  __bridge_deps__ = [...]
_DEPS_ASSIGN_RE = re.compile(
    r"^__bridge_deps__\s*=\s*\[[^\]]*\]", re.MULTILINE)


def deps_from_source(source):
    """Extracts the script dependency list from a top-level
    ``__bridge_deps__ = ["numpy", "pandas>=2"]`` assignment.

    A strict regex on the FIRST top-level assignment keeps this cheap and
    robust for any syntax error elsewhere in the file (the executor parses
    the real AST only when the list is present). Non-string entries are
    ignored; the result keeps source order and never contains duplicates.
    """
    match = _DEPS_ASSIGN_RE.search(source or "")
    if not match:
        return []
    try:
        tree = ast.parse(match.group(0))
    except SyntaxError:
        return []
    for node in tree.body:
        if isinstance(node, ast.Assign) and \
                any(isinstance(t, ast.Name) and t.id == "__bridge_deps__"
                    for t in node.targets):
            if isinstance(node.value, (ast.List, ast.Tuple)):
                deps = []
                for elt in node.value.elts:
                    if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                        name = elt.value.strip()
                        if name and name not in deps:
                            deps.append(name)
                return deps
    return []


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

    # Positional params: posonlyargs + args bilden EINE Sequenz; defaults
    # binden von HINTEN. Getrennte Indizierung verfälscht Defaults (z. B.
    # def f(a, b, /, c=1, d=2) bekam a/b faelschlich c/d-Defaults).
    all_pos = list(args.posonlyargs) + list(args.args)
    ndefaults = len(args.defaults)
    first_default = len(all_pos) - ndefaults
    n_posonly = len(args.posonlyargs)
    for i, a in enumerate(all_pos):
        has_def = i >= first_default
        default = args.defaults[i - first_default] if has_def else None
        kind = "posonly" if i < n_posonly else "pos"
        add(a.arg, kind, has_def, default, a.annotation)

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