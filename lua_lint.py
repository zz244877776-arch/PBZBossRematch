"""Reports reads of names that are neither in scope at that point nor known globals.

Catches the "local function used above its definition" class of bugs, which a plain
syntax check cannot see because Lua silently treats such names as globals.
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent / "pytools"))
from luaparser import ast, astnodes as n

KNOWN_GLOBALS = set("""
print pairs ipairs type tostring tonumber pcall xpcall error require string table math os io debug next select
setmetatable getmetatable rawget rawset rawequal loadfile load assert _G coroutine utf8 package collectgarbage
FindAllOf FindFirstOf FindObject StaticFindObject StaticConstructObject RegisterHook UnregisterHook RegisterKeyBind
Key ModifierKey LoopAsync ExecuteInGameThread ExecuteWithDelay ExecuteAsync NotifyOnNewObject RegisterLoadMapPostHook
RegisterLoadMapPreHook RegisterBeginPlayPostHook RegisterBeginPlayPreHook FName FText CreateInvalidObject
""".split())


class Linter:
    def __init__(self, path):
        self.path = path
        self.problems = []

    def report(self, node, name):
        line = getattr(node, "line", None) or (node.first_token.line if getattr(node, "first_token", None) else "?")
        self.problems.append(f"{self.path.name}:{line}: '{name}' is not defined at this point")

    def visit_block(self, stmts, scope):
        scope = [set()] + scope
        for s in stmts:
            self.visit(s, scope)

    def function(self, args, body, scope, extra=()):
        inner = [set(extra)]
        for a in args:
            if isinstance(a, n.Name):
                inner[0].add(a.id)
        self.visit_block(body.body if isinstance(body, n.Block) else body, inner + scope)

    def defined(self, name, scope):
        return any(name in s for s in scope) or name in KNOWN_GLOBALS

    def visit(self, node, scope):
        if node is None:
            return
        if isinstance(node, list):
            for x in node:
                self.visit(x, scope)
            return
        if isinstance(node, n.Block):
            return self.visit_block(node.body, scope)
        if isinstance(node, n.Chunk):
            return self.visit(node.body, scope)
        if isinstance(node, n.LocalAssign):
            self.visit(node.values, scope)
            for t in node.targets:
                scope[0].add(t.id)
            return
        if isinstance(node, n.LocalFunction):
            scope[0].add(node.name.id)
            return self.function(node.args, node.body, scope)
        if isinstance(node, n.Method):
            self.visit(node.source, scope)
            return self.function(node.args, node.body, scope, extra=("self",))
        if isinstance(node, n.Function):
            if isinstance(node.name, n.Name):
                scope[-1].add(node.name.id)
            else:
                self.visit(node.name, scope)
            return self.function(node.args, node.body, scope)
        if isinstance(node, n.AnonymousFunction):
            return self.function(node.args, node.body, scope)
        if isinstance(node, n.Fornum):
            self.visit([node.start, node.stop, node.step], scope)
            return self.visit_block(node.body.body, [{node.target.id}] + scope)
        if isinstance(node, n.Forin):
            self.visit(node.iter, scope)
            return self.visit_block(node.body.body, [{t.id for t in node.targets}] + scope)
        if isinstance(node, n.Assign):
            self.visit(node.values, scope)
            for t in node.targets:
                if isinstance(t, n.Name):
                    if not self.defined(t.id, scope):
                        scope[-1].add(t.id)
                else:
                    self.visit(t, scope)
            return
        if isinstance(node, n.Name):
            if not self.defined(node.id, scope):
                self.report(node, node.id)
            return
        if isinstance(node, n.Index):
            self.visit(node.value, scope)
            if node.notation == n.IndexNotation.SQUARE:
                self.visit(node.idx, scope)
            return
        if isinstance(node, n.Invoke):
            self.visit(node.source, scope)
            return self.visit(node.args, scope)
        if isinstance(node, n.Field):
            if getattr(node, "between_brackets", False):
                self.visit(node.key, scope)
            return self.visit(node.value, scope)
        if isinstance(node, n.Node):
            for key, value in vars(node).items():
                if key.startswith("_") or key in ("comments", "first_token", "last_token", "line", "start_char", "stop_char"):
                    continue
                if isinstance(value, (n.Node, list)):
                    self.visit(value, scope)


def main():
    problems = []
    for root in sys.argv[1:]:
        for f in sorted(pathlib.Path(root).rglob("*.lua")):
            tree = ast.parse(f.read_text(encoding="utf-8"))
            linter = Linter(f)
            linter.visit(tree, [set()])
            problems += linter.problems
    for p in problems:
        print(p)
    print(f"{len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
