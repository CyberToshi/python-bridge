"""Cython-Beispiel: derselbe Aufrufweg wie .py, nur kompiliert.

Der Build läuft automatisch vor dem ersten call_script (oder manuell über
compile_cython() bzw. "⋯ → Cython kompilieren"). Nur Desktop — im Web-Export
gibt es keinen C-Compiler.
"""

__bridge_deps__ = []


def dot(list a, list b):
    cdef double total = 0.0
    cdef int i
    for i in range(len(a)):
        total += a[i] * b[i]
    return total
