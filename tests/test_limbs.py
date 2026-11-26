"""Offline tests for the limb editing in modstudio/limbs.lua (pure text part).
Run: python3 -I tests/test_limbs.py [optional/real/mod.tbm to round-trip]"""
import sys, os
from lupa import LuaRuntime
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("MS = { settings = {}, undo = function() end, redo = function() end }")
lua.execute(open(f"{root}/modstudio/limbs.lua", encoding="utf-8").read())
L = lua.globals().MS.Limbs
n = 0
def check(name, cond):
    global n
    if not cond: print("FAIL", name); sys.exit(1)
    n += 1; print("ok  ", name)

SAMPLE = """#!/usr/bin/toribash
version 15
gamerule
   numplayers 2
env_obj 1
   shape box
   pos 0 0 0
player 0
   body head
      sides 0.2 0 0
   joint neck
      radius 0.1
player 1
   body head
      sides 0.2 0 0
   joint neck
      radius 0.1
"""
doc = L.parse(SAMPLE)
check("round trip unchanged", L.build(doc) == SAMPLE)
f = L.fighters(doc)
f0, f1 = f[0], f[1]
check("both fighters found", f0 is not None and f1 is not None)
L.addBody(f0, lua.eval("{ name = 'tail1', pos = {1, 2, 3}, sides = {0.1, 0.1, 0.1} }"))
L.addJoint(f0, lua.eval("{ name = 'tailj', parent = 'groin', child = 'tail1', pos = {1, 2, 2.9} }"))
out = L.build(doc)
check("env_obj 0 added once", out.count("   env_obj 0" + chr(10)) == 1)
check("body before joint", out.index("body tail1") < out.index("joint tailj"))
check("connect written", "      connect groin tail1" in out)
check("player 1 untouched", out.split("player 1")[1] == SAMPLE.split("player 1")[1])
d2 = L.parse(out); g0 = L.fighters(d2)[0]
b, j = L.extraNames(g0)
check("extra names read back", b[1] == "tail1" and j[1] == "tailj")
L.addBody(g0, lua.eval("{ name = 'tail2', pos = {0,0,0} }"))
L.addJoint(g0, lua.eval("{ name = 'tailj2', parent = 'tail1', child = 'tail2' }"))
out2 = L.build(d2)
check("second body goes after first body", out2.index("body tail1") < out2.index("body tail2") < out2.index("joint tailj"))
check("only one env_obj 0", out2.count("   env_obj 0" + chr(10)) == 1)
check("nothing cut off", len(L.cutOff(g0, L.connections(g0))) == 0)
conns = L.connections(g0); conns.tailj = None
lost = L.cutOff(g0, conns)
check("removing tailj would cut tail1, tail2", list(lost.values()) == ["tail1", "tail2"])
L.rename(g0, "body", "tail1", "tailbase")
out3 = L.build(d2)
check("rename body + connects", "body tailbase" in out3 and "connect groin tailbase" in out3 and "connect tailbase tail2" in out3 and "tail1" not in out3)
gone = L.remove(g0, "body", "tail2")
check("remove body takes its joint", list(gone.values()) == ["tailj2"] and "tail2" not in L.build(d2))
L.connect(g0, "neck", "breast", "tailbase")
out4 = L.build(d2)
check("classic rewire inserted before extras", out4.index("connect breast tailbase") < out4.index("env_obj 0"))
check("classic rewire read", L.connections(g0).neck[2] == "tailbase")
L.connect(g0, "neck", "chest", "tailbase")
check("rewire replaces line", L.build(d2).split("player 1")[0].count("joint neck") == 2 and "connect chest tailbase" in L.build(d2))
L.remove(g0, "body", "tailbase")
out5 = L.build(d2)
check("removing body resets classic joint wired to it", "connect chest tailbase" not in out5 and L.build(d2).split("player 1")[0].count("joint neck") == 1)
check("valid names", L.validName("r_tail-2") and not L.validName("bad name") and not L.validName("x" * 32))
check("number format", L.num(1.0) == "1" and L.num(-0.00001) == "0" and L.num(0.125) == "0.125")
check("CRLF kept", L.build(L.parse(SAMPLE.replace("\n", "\r\n"))) == SAMPLE.replace("\n", "\r\n"))
check("free names", L.freeName(L.parse(out2), "body", "tail") == "tail3")

BARE = chr(10).join(["#!/usr/bin/toribash", "version 15", "gamerule", "   numplayers 2", ""])
bd = L.parse(BARE)
check("classic export has no fighters", L.fighters(bd)[0] is None)
nf = L.fighter(bd, 1); L.fighter(bd, 0)
L.addBody(nf, lua.eval("{ name = 'tail1' }"))
bo = L.build(bd)
check("missing fighters are created in order", bo.index("player 0") < bo.index("player 1") < bo.index("body tail1"))
check("created fighter gets env_obj 0", "   env_obj 0" + chr(10) in bo.split("player 1")[1])
check("same fighter returned again", lua.eval("function(a, b) return a == b end")(L.fighter(bd, 1), nf))

# Reading / writing an extra part's values (the game's get/set_mod_body refuse extra limbs)
fd = L.parse(SAMPLE); ff = L.fighters(fd)[0]
L.addBody(ff, lua.eval("{ name = 'tail1', pos = {1, 2, 3}, sides = {0.1, 0.2, 0.3}, density = 0.5 }"))
L.addJoint(ff, lua.eval("{ name = 'tj', parent = 'groin', child = 'tail1', pos = {1, 2, 2.5}, range = {0.7, -0.4}, strength = 3 }"))
bb = L.blockOf(ff, "body", "tail1"); jb = L.blockOf(ff, "joint", "tj")
bo = L.readFields(bb, "body"); jo = L.readFields(jb, "joint")
check("body fields read", bo.pos_z == 3 and bo.sides_y == 0.2 and bo.density == 0.5 and bo.rot_x == 0)
check("joint fields read", jo.histop == 0.7 and jo.lostop == -0.4 and jo.maxforce == 3 and jo.pos_z == 2.5)
bo.pos_x = 4.25; bo.rot_y = 30
L.writeFields(bb, "body", bo, lua.eval("{ pos = true, rot = true }"))
out6 = L.build(fd)
check("pos line replaced", "      pos 4.25 2 3" in out6 and out6.count("pos 1 2 3") == 0)
check("missing rot line added", "      rot 0 30 0" in out6)
jo.lostop = -1.5
L.writeFields(jb, "joint", jo, lua.eval("{ range = true }"))
check("range written from both limits", "      range 0.7 -1.5" in L.build(fd))
check("edited file reads back", L.readFields(L.blockOf(L.fighters(L.parse(L.build(fd)))[0], "body", "tail1"), "body").pos_x == 4.25)

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8", errors="replace").read()
    d = L.parse(text)
    check("real mod round trip: " + os.path.basename(path), L.build(d) == text if text.endswith("\n") else L.build(d) == text + "\n")
    for p, fi in L.fighters(d).items():
        b, j = L.extraNames(fi)
        check(f"fighter {p}: {len(b)} extra bodies, {len(j)} extra joints, none cut off", len(L.cutOff(fi, L.connections(fi))) == 0)
print(n, "checks passed")
