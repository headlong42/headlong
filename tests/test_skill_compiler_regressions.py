"""Offline black-box regressions, invoked by test_skill_compiler.sh.

All skills, model responses, trajectories, credentials and workdirs are synthetic.
The same checks can be pointed at a copy of the pre-fix compiler.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

SC = Path(sys.argv[1]).resolve()
ROOT = Path(sys.argv[2]).resolve()
ROOT.mkdir(parents=True, exist_ok=True)
STUBS = ROOT / 'stubs'
STUBS.mkdir()
PYTHON = sys.executable
REAL_JQ = shutil.which('jq')

STUB = r'''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ['CASE_ROOT'])
argv_max = max([0] + [len(x.encode()) for x in sys.argv[1:]])
env_max = max(len((k+'='+v).encode()) for k,v in os.environ.items())
with (root/'exec-sizes.jsonl').open('a') as f:
    f.write(json.dumps(dict(tool=name, argv=argv_max, env=env_max))+'\n')
if os.environ.get('LIMIT_PROBE') == '1' and max(argv_max,env_max) >= 131072:
    print('Linux-sized exec string limit exceeded',file=sys.stderr)
    sys.exit(90)
if name == 'jq':
    os.execv(os.environ['REAL_JQ'], ['jq']+sys.argv[1:])
if name == 'python3':
    os.execv(os.environ['REAL_PYTHON'], ['python3']+sys.argv[1:])
if name == 'mkdir':
    if os.environ.get('BREAK_NEXT_SETUP') == '1' and sys.argv[-1].endswith('/traj'):
        counter=root/'setup-count'
        n=int(counter.read_text())+1 if counter.exists() else 1
        counter.write_text(str(n))
        if n==2: sys.exit(1)
    os.execv('/bin/mkdir', ['mkdir']+sys.argv[1:])
if name == 'skills':
    sys.exit(0)
if name == 'llm':
    (root/'teacher-args.json').write_text(json.dumps(sys.argv[1:]))
    prompt = sys.stdin.read()
    if not prompt and len(sys.argv)>1: prompt=sys.argv[-1]
    (root/'teacher-prompt').write_text(prompt)
    print((root/'tests.json').read_text())
    sys.exit(0)
if name == 'shellm':
    args=sys.argv[1:]
    if '--prompt-file' in args:
        prompt=pathlib.Path(args[args.index('--prompt-file')+1]).read_text()
    else: prompt=args[-1]
    (root/'shell-prompt').write_text(prompt)
    traj=pathlib.Path(os.environ['TRAJ_DIR']);traj.mkdir(parents=True,exist_ok=True)
    (traj/'stub.jsonl').write_text((root/'trajectory.jsonl').read_text())
    if (root/'fixture.txt').exists():
        (pathlib.Path(os.environ['SHELLM_RUNDIR'])/'input.txt').write_text((root/'fixture.txt').read_text())
    sys.exit(0)
'''
for name in ('llm', 'shellm', 'skills', 'jq', 'python3', 'mkdir'):
    p = STUBS / name
    p.write_text('#!' + PYTHON + '\n' + STUB)
    p.chmod(0o755)

count = 0
failed = 0


def check(name, fn):
    global count, failed
    if os.environ.get('REGRESSION_FILTER') and os.environ['REGRESSION_FILTER'] not in name:
        return
    count += 1
    try:
        fn()
        print('ok   regression: ' + name, flush=True)
    except Exception as exc:
        failed += 1
        print('FAIL regression: ' + name + ': ' + str(exc)[:500], flush=True)


class Case:
    def __init__(self, name):
        self.root = ROOT / name
        self.root.mkdir()
        self.skills = self.root / 'skills & #'
        self.skills.mkdir()
        self.cache = SC.parent / '.compiled'
        shutil.rmtree(self.cache, ignore_errors=True)
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(('SKILL_', 'SC_', 'SHELLM_', 'HEADLONG_', 'LLM_', 'TRAJ_', 'MEM_', 'ROOT_TRAJ_')):
                self.env.pop(key)
        self.env.update(HOME=str(self.root/'home'), HEADLONG_HOME=str(self.root/'state'),
                        SKILLS_DIR=str(self.skills), SKILLS_KERNEL_DIR=str(self.root/'kernel'),
                        SKILL_COMPILED_DIR=str(self.cache), SC_TMP_BASE=str(self.root/'tmp'),
                        SC_RUNS_BASE=str(self.root/'runs'), SHELLM_ENV='local', SKILL_AUTO_HARVEST='0',
                        PATH=str(STUBS)+os.pathsep+os.environ['PATH'], CASE_ROOT=str(self.root),
                        REAL_JQ=REAL_JQ, REAL_PYTHON=PYTHON)
        (self.root/'home').mkdir()
        self.skill('probe', 'Run python3 probe.py.\n', 'print("Victory phrase stable")\n')
        self.tests([dict(name='probe-test', prompt='Run the probe.', expect='final',
                         expect_contains=['Victory phrase stable'])])
        self.output('Victory phrase stable')

    def skill(self, name, body='', script=None):
        d=self.skills/name; d.mkdir(exist_ok=True)
        (d/'SKILL.md').write_text('---\nname: '+name+'\ndescription: Fixture.\n---\n'+body)
        if script is not None: (d/(name+'.py')).write_text(script)
        return d

    def tests(self, tests):
        (self.root/'tests.json').write_text(json.dumps(tests))

    def output(self, text, final='Reported.'):
        records=[dict(type='shell-output', stdout=text), dict(type='final',content=final)]
        (self.root/'trajectory.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in records))

    def run(self, command='compile', skill='probe', extra=(), success=True):
        r=subprocess.run(['/bin/bash' if sys.platform=='darwin' else 'bash', str(SC), command, '--skill',skill,*extra],
                         env=self.env,cwd=self.root,text=True,capture_output=True,timeout=90)
        with (self.root/'commands.log').open('a') as f:
            f.write(f'{command} {skill}: rc={r.returncode}\n'+r.stdout+r.stderr)
        if success: assert r.returncode==0, (r.stderr+r.stdout)[-600:]
        return r

    def result(self):
        return json.loads((self.cache/'probe.json').read_text())


def fixture_only():
    c=Case('fixture-only'); c.output('', 'No work happened.')
    (c.root/'fixture.txt').write_text('prefix Victory phrase stable suffix\n')
    c.run(); assert c.result()['tests'][0]['pass'] is False
check('fixture text is not executed evidence',fixture_only)


def interleaved():
    c=Case('interleaved'); td=c.root/'trajectories';td.mkdir()
    records=[dict(type='reasoning',run_id='a',cmd='python3 probe.py'),
             dict(type='reasoning',run_id='b',cmd='echo unrelated'),
             dict(type='shell-output',run_id='a',stdout='Correct probe verdict'),
             dict(type='shell-output',run_id='b',stdout='Unrelated other verdict'),
             dict(type='reasoning',run_id='c',cmd='python3 probe.py'),
             dict(type='shell-output',run_id='d',stdout='Incorrectly attributed verdict'),
             dict(type='shell-output',run_id='c',stdout='Correct second verdict')]
    (td/'events.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in records))
    c.env.update(SKILL_AUTO_HARVEST='1',SKILL_HARVEST_TRAJ_DIR=str(td),SKILL_HARVEST_MIN_COUNT='1')
    pool=json.loads(c.run('pool').stdout)
    assert 'Correct probe verdict' in pool and 'Correct second verdict' in pool
    assert 'Incorrectly attributed verdict' not in pool and 'Unrelated other verdict' not in pool
check('history follows run_id',interleaved)


def live(kind):
    c=Case('live-'+kind);d=c.skills/'probe'
    (d/'probe.py').unlink()
    (d/'SKILL.md').write_text('---\nname: probe\n---\nRun probe.'+kind+'\n')
    (d/('probe.'+kind)).write_text('print("".join(["runtime", " computed", " phrase"]))\n' if kind=='py'
                                  else 'printf "%s %s %s\\n" runtime computed phrase\n')
    # Relative configured roots must also become absolute before cd.
    c.env['SKILLS_DIR']=os.path.relpath(c.skills,c.root)
    assert 'runtime computed phrase' in json.loads(c.run('pool').stdout)
check('Python live-only vocabulary',lambda:live('py'))
check('shell live-only vocabulary',lambda:live('sh'))


def provenance():
    c=Case('provenance');h=c.root/'history.json'
    h.write_text(json.dumps(dict(script='probe.py',entries=[dict(line='Victory phrase stable',count=2)])))
    c.env['SKILL_HISTORY_POOL']=str(h)
    c.tests([dict(name='metadata',prompt='Run the probe.',expect='final',expect_contains=['probe.py','Victory phrase stable'])])
    c.output('probe.py Victory phrase stable');c.run()
    labels=c.result()['tests'][0]['literal_sources']
    assert labels['probe.py']!='TOOL-OUTPUT' and labels['Victory phrase stable']=='TOOL-OUTPUT'
check('history metadata is not captured output',provenance)


def empty_capture():
    c=Case('empty-capture');f=c.root/'empty.txt';f.write_text('')
    c.env['SKILL_REAL_OUTPUT']=str(f);c.run()
    assert c.result()['tests'][0]['literal_sources']['Victory phrase stable']=='SCRIPT-PRINT-UNATTESTED'
check('an empty capture is still occurrence evidence of absence',empty_capture)


def cap(kind):
    c=Case('cap-'+kind); target='zeta dropped real phrase'
    c.env.update(SKILL_POOL_CAP='1000', SKILL_POOL_SRC_CAP='1000',SKILL_POOL_LIVE_CAP='1000')
    if kind=='source':
        (c.skills/'probe'/'probe.py').write_text('import sys\nif len(sys.argv)==1: sys.exit(0)\n# print("alpha first phrase")\n# print("zeta dropped real phrase")\n')
        c.env['SKILL_POOL_SRC_CAP']='1'
    elif kind=='doc':
        c.skill('probe','`alpha first phrase`\n`zeta dropped real phrase`\n')
        (c.skills/'probe'/'probe.py').unlink();c.env['SKILL_POOL_SRC_CAP']='1'
    elif kind=='live':
        (c.skills/'probe'/'probe.py').write_text('print("alpha first phrase")\nprint(" ".join(["zeta", "dropped", "real", "phrase"]))\n')
        c.env['SKILL_POOL_LIVE_CAP']='1'
    else:
        h=c.root/'history.json';h.write_text(json.dumps(['alpha first phrase',target]))
        c.env.update(SKILL_HISTORY_POOL=str(h), SKILL_HARVEST_MAX_ENTRIES='1')
    c.tests([dict(name='cap',prompt='Run the probe.',expect='final',expect_contains=[target])])
    c.output(target);c.run();r=c.result()
    assert r['summary']['pool_truncated'] is True
    assert r['tests'][0]['literal_labels'][target]=='POOL-DROPPED'
    assert r['tests'][0]['verification']=='GREEN-ON-DROPPED'
for kind in ('source','doc','live','history'):check(kind+' cap retains dropped vocabulary',lambda k=kind:cap(k))


def refused():
    c=Case('refused');d=c.skill('slack','Run slack.py.\n','print("never execute")\n')
    (c.skills/'alias').symlink_to(d,target_is_directory=True)
    escaped=c.skill('escape');(escaped/'SKILL.md').unlink();(escaped/'SKILL.md').symlink_to(d/'SKILL.md')
    c.skill('declared');(c.skills/'declared'/'SKILL.md').write_text('---\nname: slack\n---\n')
    accepted=[]
    for name in ('slack','slack/','./slack','../skills & #/slack','alias','escape','declared'):
        for cmd in ('compile','pool'):
            marker=c.root/'teacher-args.json'
            if marker.exists(): marker.unlink()
            r=c.run(cmd,name,success=False)
            if r.returncode==0 or marker.exists(): accepted.append(f'{cmd} {name}')
    # A normal installer-style link retains its basename and is supported.
    d=c.root/'installed'/'safe';d.mkdir(parents=True);(d/'SKILL.md').write_text('---\nname: safe\n---\n')
    (c.skills/'safe').symlink_to(d,target_is_directory=True);c.run('pool','safe')
    assert not accepted, 'accepted: '+', '.join(accepted)
check('refusal spellings, aliases, escaped spec, and installed symlink',refused)


def rewriting():
    c=Case('paths');absolute=str(c.skills/'probe'/'probe.py')
    c.tests([dict(name='paths',prompt='Run skills/probe/probe.py and '+absolute,expect='final',expect_contains=[])])
    c.run();p=(c.root/'shell-prompt').read_text()
    assert 'Run '+absolute+' and '+absolute in p
check('stock macOS path rewriting preserves absolute paths and special characters',rewriting)


def parser_provider():
    c=Case('parser');spec=c.skills/'probe'/'SKILL.md'
    spec.write_text('---\nname: probe\ndescription: secret metadata marker\nmetadata:\n  shelllm:\n    requires:\n      bins: [bash, definitely-absent]\n---\nBody.\n---\n## Usage\nlast usage line\n')
    c.env.update(SHELLM_MODEL='configured-model',LLM_PROVIDER='adapter')
    c.run(extra=('--teacher-model','explicit-model'))
    args=json.loads((c.root/'teacher-args.json').read_text())
    assert '--provider' not in args and args==['-m','explicit-model']
    text=(c.root/'teacher-prompt').read_text()
    obj,_=json.JSONDecoder().raw_decode(text.split('SKILL SPECIFICATION (JSON):\n')[1])
    assert obj['body']=='Body.\n---\n## Usage\nlast usage line\n'
    assert obj['usage_section'].endswith('last usage line\n')
    assert 'definitely-absent: NOT INSTALLED' in text
    c.run();assert json.loads((c.root/'teacher-args.json').read_text())==[]
    (c.root/'shell-prompt').unlink();c.tests([dict(name='invalid',prompt='Run.',expect='thought')])
    assert c.run(success=False).returncode!=0 and not (c.root/'shell-prompt').exists()
check('frontmatter, terminal Usage, declared binaries and provider delegation',parser_provider)


def negatives():
    c=Case('negative-matcher')
    rows=[('missing',['missing phrase'],'Victory phrase stable',False),
          ('denial',['violation'],'No violations found',False),
          ('clean-but-asserts-violation',['violation'],'No violations found',False),
          ('digit',['5 tests passed'],'15 tests passed',False),
          ('and',['Victory phrase stable','missing phrase'],'Victory phrase stable',False),
          ('clean',['No violations found'],'No violations found',True),
          ('digit-ok',['5 tests passed'],'5 tests passed',True),
          ('positive',['Victory phrase stable'],'Victory phrase stable',True)]
    for name,literals,out,want in rows:
        c.tests([dict(name=name,prompt='Run the probe.',expect='final',expect_contains=literals)])
        c.output(out);c.run();assert c.result()['tests'][0]['pass']==want,name
    # Exact prompt echoes must not become evidence, including the final answer.
    c.tests([dict(name='echo',prompt='Victory phrase stable',expect='final',expect_contains=['Victory phrase stable'])])
    c.output('Victory phrase stable','Victory phrase stable');c.run()
    assert c.result()['tests'][0]['pass'] is False
    fixture=json.dumps(dict(message='Victory phrase stable'))
    (c.root/'fixture.txt').write_text(fixture+'\n')
    c.tests([dict(name='fixture-echo',prompt='Run the probe.',expect='final',expect_contains=['Victory phrase stable'])])
    c.output(fixture,fixture);c.run();assert c.result()['tests'][0]['pass'] is False
    (c.root/'fixture.txt').unlink()
    c.tests([dict(name='empty',prompt='Run.',expect='final',expect_contains=[])])
    c.output('','');c.run();assert c.result()['tests'][0]['pass'] is False
    c.output('','Answered.');c.run();assert c.result()['tests'][0]['verification']=='GREEN-NO-LITERALS'
check('missing, denial, digit boundaries, AND, echoes and empty final/literals',negatives)


def large():
    c=Case('large');c.env['LIMIT_PROBE']='1'
    big='long evidence '*11000
    c.skill('probe', 'Large body '+big+'\n')
    c.tests([dict(name='large',prompt='Run the probe. '+big,expect='final',expect_contains=[big.strip()])]*2)
    c.output(big,big);c.run();r=c.result()
    assert len(r['tests'])==2 and all(x['pass'] for x in r['tests']), [(x.get('pass'), x.get('last_step_type'), x.get('expect_contains_matched'), x.get('harness_error')) for x in r['tests']]
    sizes=[json.loads(x) for x in (c.root/'exec-sizes.jsonl').read_text().splitlines()]
    assert max(max(x['argv'],x['env']) for x in sizes)<131072
    assert (c.cache/'probe.json').stat().st_size>131072
check('large skill, prompts, literals, answers and aggregate results avoid exec limits',large)


def lifecycle():
    c=Case('lifecycle');r=c.run()
    assert 'Running test 1/1: probe-test' in r.stdout and 'Test result: true' in r.stdout
    assert not list((c.root/'tmp').glob('run.*'))
    assert not list((c.root/'runs').glob('*'))
    c.run('clean'); assert not [p for p in c.cache.iterdir() if 'probe' in p.name]
    c.env.pop('SKILL_COMPILED_DIR');c.run()
    assert (c.root/'state'/'skill-compiler'/'compiled'/'probe.json').exists()
check('progress, temporary cleanup, complete clean and persistent state cache',lifecycle)


def partial():
    c=Case('partial');c.env['BREAK_NEXT_SETUP']='1'
    t=json.loads((c.root/'tests.json').read_text())[0];c.tests([t,dict(t,name='second')])
    r=c.run(success=False);assert r.returncode!=0
    results=c.result()['tests'];assert results[0]['pass'] and not results[1]['pass']
    assert 'harness_error' in results[1]
check('setup failure retains preceding results and records a failed test',partial)


def history_defaults():
    c=Case('history-defaults');td=c.root/'state'/'trajectories';td.mkdir(parents=True)
    rows=[dict(type='reasoning',cmd='python3 probe.py'),dict(type='shell-output',stdout='Notes: A1 B2 C3\nVerdict line from history')]*2
    f=td/'test.jsonl';f.write_text(''.join(json.dumps(x)+'\n' for x in rows))
    c.env['SKILL_AUTO_HARVEST']='1';pool=json.loads(c.run('pool').stdout)
    assert 'Notes: A1 B2 C3' in pool  # music filter is not generic output policy
    h=c.root/'state'/'skill-compiler'/'history'/'pool-history-probe.json';before=h.stat().st_mtime_ns
    c.run('pool');assert h.stat().st_mtime_ns==before
    # Explicit music opt-in must invalidate the generic cached view.
    c.env['SKILL_HARVEST_ECHO_FILTER']='music';pool=json.loads(c.run('pool').stdout)
    assert 'Notes: A1 B2 C3' not in pool and 'Verdict line from history' in pool
    c.env.pop('HEADLONG_HOME');c.env.pop('SKILL_HARVEST_ECHO_FILTER')
    legacy=c.root/'home'/'.shellm';shutil.copytree(c.root/'state',legacy)
    pool=json.loads(c.run('pool').stdout);assert 'Verdict line from history' in pool
check('state-home history, reusable TTL and opt-in music filter',history_defaults)

print(f'{count-failed} regression checks passed, {failed} failed',flush=True)
sys.exit(bool(failed))
