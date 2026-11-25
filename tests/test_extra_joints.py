"""Offline tests for the extra-joints read support in core.lua.
Run: python3 -I tests/test_extra_joints.py   (loads real source, stubs the game API)"""
import sys, os, re
from lupa import LuaRuntime
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(f"{root}/modstudio/core.lua").read()
helpers = src[src.index("---Extra joints (Toribash alpha 2)"):src.index("MS.BODY_MIRROR = {")]
def func(name):
    m = re.search(r"^function MS\.%s\(.*?^end\n" % name, src, re.S | re.M)
    assert m, name
    return m.group(0)
lua = LuaRuntime(unpack_returned_tuples=True)
n = 0
def check(name, cond):
    global n
    if not cond: print("FAIL", name); sys.exit(1)
    n += 1; print("ok  ", name)

def fresh(extra_api=True):
    lua.execute("""
    MS = { NUM_BODIES = 21, NUM_JOINTS = 20, BODIES = nil,
      BODY_NAMES = {[0]="Head","Breast"}, JOINT_NAMES = {[0]="Neck","Chest"},
      BODY_FIELDS = {"pos_x","sides_x"}, JOINT_FIELDS = {"pos_x","radius"},
      unsupported = { body = {}, joint = {} }, bodies = {}, joints = {} }
    normalize = function(f, v) return v end
    fromEngine = function(f, v) return v end
    get_num_bodies, get_num_joints, get_joint_bodies, get_body_info, get_joint_info, get_mod_body, get_mod_joint = nil
    """)
    lua.execute(helpers)
    lua.execute(func("readBody")); lua.execute(func("readJoint"))
fresh()
g = lua.globals()
M = g.MS
check("older game: classic counts", M.numBodies(0) == 21 and M.numJoints(0) == 20)
lua.execute("get_num_bodies = function(p) return 24 end; get_num_joints = function(p) return 23 end")
check("alpha 2: extra counts", M.numBodies(0) == 24 and M.numJoints(1) == 23)
lua.execute("get_num_bodies = function(p) return 5 end")
check("nonsense count ignored", M.numBodies(0) == 21)
lua.execute("get_num_bodies = function(p) error('boom') end")
check("erroring count ignored", M.numBodies(0) == 21)
lua.execute("get_body_info = function(p, b) return { name = 'tail1', mod_name = 'Tail 1' } end; get_joint_info = function(p, j) return { name = 'tj' } end")
check("classic names kept", M.bodyName(0, 1) == "Breast" and M.jointName(0, 1) == "Chest")
check("extra body uses mod name", M.bodyName(0, 21) == "Tail 1")
check("extra joint falls back to name", M.jointName(0, 20) == "tj")
lua.execute("get_body_info = function(p, b) return nil end")
check("unknown extra gets a label", M.bodyName(1, 30) == "Extra body 30")
lua.execute("get_num_bodies = function(p) return 23 end")
names = M.bodyNameList(0)
check("name list covers extras", names[0] == "Head" and names[22] is not None and names[23] is None)
lua.execute("get_joint_bodies = function(p, j) return 3, 22 end")
a, b = M.jointBodies(0, 20)
check("joint bodies (two values)", a == 3 and b == 22)
lua.execute("get_joint_bodies = function(p, j) return {4, 5} end")
a, b = M.jointBodies(0, 20)
check("joint bodies (table)", a == 4 and b == 5)
lua.execute("get_joint_bodies = nil")
check("joint bodies absent on old game", M.jointBodies(0, 2) is None)
lua.execute("get_joint_bodies = function() error('x') end")
check("joint bodies error tolerated", M.jointBodies(0, 2) is None)

# reading: failures on extra parts must not hide fields on classic parts
lua.execute("get_mod_body = function(p, b, f) if b >= 21 then error('no such body') end return 1 end")
check("classic body reads", M.readBody(0, 3) is not None and M.unsupported.body.pos_x is None)
check("unreadable extra body is skipped", M.readBody(0, 22) is None)
check("...without marking fields unsupported", M.unsupported.body.pos_x is None and M.unsupported.body.sides_x is None)
lua.execute("get_mod_body = function(p, b, f) if f == 'sides_x' and b >= 21 then error('x') end return 2 end")
o = M.readBody(0, 21)
check("partly readable extra keeps what it read", o is not None and o.pos_x == 2 and M.unsupported.body.sides_x is None)
lua.execute("get_mod_body = function(p, b, f) if f == 'sides_x' then error('x') end return 2 end")
M.readBody(0, 3)
check("classic failure still marks unsupported", M.unsupported.body.sides_x == True)
lua.execute("get_mod_joint = function(p, j, f) if j >= 20 then error('nope') end return 1 end")
check("unreadable extra joint skipped, classic untouched", M.readJoint(0, 21) is None and M.unsupported.joint.pos_x is None and M.readJoint(0, 5) is not None)
lua.execute("get_mod_body = function() error('player index out of range') end")
check("missing player still stops the scan", M.readBody(2, 0) is None)
print(f"\nall {n} checks passed")
