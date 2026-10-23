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
if name == 'sleep':
    with (root/'sleeps').open('a') as f: f.write(sys.argv[1]+'\n')
    sys.exit(0)
if name == 'llm':
    counter=root/'teacher-count'
    n=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n))
    (root/'teacher-args.json').write_text(json.dumps(sys.argv[1:]))
    prompt = sys.stdin.read()
    if not prompt and len(sys.argv)>1: prompt=sys.argv[-1]
    (root/'teacher-prompt').write_text(prompt)
    if n <= int(os.environ.get('TEACHER_FAILURES','0')):
        print('synthetic teacher failure',file=sys.stderr)
        sys.exit(1)
    if os.environ.get('TEACHER_EMPTY') == '1': sys.exit(0)
    print((root/'tests.json').read_text())
    sys.exit(0)
if name == 'shellm':
    (root/'runner-selectors.json').write_text(json.dumps({k:os.environ.get(k) for k in
        ('CHATRC','SKILLSRC','THINKERS_DIR','SHELLM_BROKER_DIR')}))
    if os.environ.get('MUTATE_POOL'):
        pool=pathlib.Path(os.environ['SKILL_COMPILED_DIR'])/'pool-probe.json'
        (root/'pool-before-mutation.json').write_text(pool.read_text())
        if os.environ['MUTATE_POOL']=='remove': pool.unlink()
        else: pool.write_text('{"offered":[],"dropped":[],"pool_dropped":0}')
    args=sys.argv[1:]
    if '--prompt-file' in args:
        prompt=pathlib.Path(args[args.index('--prompt-file')+1]).read_text()
    else: prompt=args[-1]
    (root/'shell-prompt').write_text(prompt)
    traj=pathlib.Path(os.environ['TRAJ_DIR']);traj.mkdir(parents=True,exist_ok=True)
    if os.environ.get('NO_TRAJECTORY') != '1':
        run_id='new-root-run'
        header=[dict(type='trajectory',step_id='new-root-trajectory'),
                dict(type='shellm-run',step_id=run_id)]
        rows=[json.loads(line) for line in (root/'trajectory.jsonl').read_text().splitlines()]
        rows=[dict(r,run_id=r.get('run_id',run_id)) for r in rows]
        parent=traj/'root';parent.mkdir()
        (parent/'trajectory.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in header+rows))
        if os.environ.get('SHELLM_RUN_ID_OUT') and os.environ.get('NO_RUN_HANDSHAKE') != '1':
            pathlib.Path(os.environ['SHELLM_RUN_ID_OUT']).write_text(run_id)
        if os.environ.get('NESTED_TRAJECTORY') == '1':
            child=parent/'child';child.mkdir()
            child_rows=[dict(type='trajectory',step_id='child',parent_traj='new-root-trajectory'),
                        dict(type='shellm-run',step_id='child-run'),
                        dict(type='final',content='Child-only success',run_id='child-run')]
            (child/'trajectory.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in child_rows))
        if os.environ.get('AMBIGUOUS_ROOT') == '1':
            (traj/'duplicate.jsonl').write_text((parent/'trajectory.jsonl').read_text())
    if (root/'fixture.txt').exists():
        (pathlib.Path(os.environ['SHELLM_RUNDIR'])/'input.txt').write_text((root/'fixture.txt').read_text())
    print('synthetic runner diagnostic',file=sys.stderr)
    sys.exit(int(os.environ.get('RUNNER_RC','0')))
'''
for name in ('llm', 'shellm', 'skills', 'jq', 'python3', 'mkdir', 'sleep'):
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
        self.cache = self.root / 'compiled'
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(('SKILL_', 'SC_', 'SHELLM_', 'HEADLONG_', 'LLM_', 'TRAJ_', 'MEM_', 'ROOT_TRAJ_')) or key.endswith(('_API_KEY', '_TOKEN')) or key in ('CHATRC','SKILLSRC','THINKERS_DIR'):
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
        r=subprocess.run([os.environ.get('SC_TEST_BASH', '/bin/bash' if sys.platform=='darwin' else 'bash'), str(SC), command, '--skill',skill,*extra],
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



def teacher_bytes():
    c=Case('teacher-bytes')
    body=r'cd x && y; literal \path\ and __SKILL_ABS__ __NUM_TESTS__ __BINS_STATUS__'
    phrase=r'alpha & beta \slash __SKILL_SPEC__ __SKILL_ABS__'
    c.skill('probe',body+'\n','print('+repr(phrase)+')\n')
    c.run(); text=(c.root/'teacher-prompt').read_text()
    spec,_=json.JSONDecoder().raw_decode(text.split('SKILL SPECIFICATION (JSON):\n')[1])
    pool,_=json.JSONDecoder().raw_decode(text.split('PHRASE POOL (verbatim vocabulary, not a claim of behavioral coverage):\n')[1])
    offered=json.loads((c.cache/'pool-probe.json').read_text())['offered']
    assert spec['body']==body+'\n',spec['body']
    assert pool==offered and phrase in pool
    assert str(c.skills/'probe')+'/<file>' in text
check('verbatim teacher interpolation, ampersands, backslashes and placeholder data',teacher_bytes)


def ranking():
    c=Case('ranking');c.skill('probe','Example `aaa documentation phrase`.\n','print("zzz live script phrase")\n')
    c.env['SKILL_POOL_CAP']='1'
    assert json.loads(c.run('pool').stdout)==['zzz live script phrase']
check('script and live source priority survives combined cap',ranking)


def history_ranking():
    c=Case('history-ranking')
    h=c.root/'history.json'
    h.write_text(json.dumps(dict(entries=[dict(line='aaa rare output',count=2),dict(line='zzz frequent output',count=100),dict(line='zzz frequent output',count=100)])))
    c.env.update(SKILL_HISTORY_POOL=str(h),SKILL_HARVEST_MAX_ENTRIES='1',SKILL_POOL_CAP='100')
    pool=json.loads(c.run('pool').stdout)
    assert 'zzz frequent output' in pool and 'aaa rare output' not in pool
    dropped=json.loads((c.cache/'pool-probe.json').read_text())['dropped']
    assert 'aaa rare output' in dropped
check('history frequency survives source cap and deduplication',history_ranking)


def outcome(expect):
    c=Case('outcome-'+expect)
    c.tests([dict(name='outcome',prompt='Run the probe.',expect=expect,expect_contains=[])])
    def run(rows,rc,want,harness=False):
        (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        c.env['RUNNER_RC']=str(rc)
        r=c.run(success=False);test=c.result()['tests'][0]
        assert test['pass'] is want,(expect,rows,rc,test)
        assert ('harness_error' in test) is harness
        assert (r.returncode!=0) is harness
        assert test['runner_stderr']=='synthetic runner diagnostic\n'.rstrip('\n')
    named=dict(type=expect,content='Actual evidence')
    if expect=='shell-output': named=dict(type=expect,stdout='Actual evidence',**{'exit':0})
    if expect=='error': named=dict(type='shell-output',stderr='Actual skill failure',**{'exit':2})
    # First assert the reported false-positive path on the original compiler.
    run([] if expect=='error' else [named],1,False,True)
    # Each outcome also has a valid case without requiring an unrelated final.
    run([named],0,True)
    run([dict(type='reasoning',content='Still planning')],0,False)
    if expect in ('observation','shell-output'):
        run([dict(type='final',content='Wrong evidence kind')],0,False)
    run([],1,False,True)
    run([named],1,False,True)
    if expect=='error':
        run([dict(type='error',content='Provider failed',reason='stall')],0,False)
        run([dict(type='shell-output',stderr='No failure',**{'exit':0})],0,False)
        run([dict(type='shell-output',stderr='Timed out',timed_out=True,**{'exit':124})],0,False)
    else:
        run([dict(type=expect,content=' ',stdout='')],0,False)
    literal='Actual skill failure' if expect=='error' else 'Actual evidence'
    c.tests([dict(name='named-literal',prompt='Run the probe.',expect=expect,expect_contains=[literal])])
    run([named],0,True)
    # Literals cannot rescue an unsuccessful runner, including a final answer.
    c.tests([dict(name='attested-failure',prompt='Run the probe.',expect=expect,expect_contains=['Victory phrase stable'])])
    run([dict(named,content='Victory phrase stable',stdout='Victory phrase stable')],1,False,True)
    assert c.result()['tests'][0]['verification']=='FAIL'
for expected in ('final','observation','shell-output','error'):
    check('runner success and named evidence for '+expected,lambda e=expected:outcome(e))


def root_selection():
    c=Case('root-selection');c.env['NESTED_TRAJECTORY']='1'
    c.tests([dict(name='root',prompt='Run the probe.',expect='final',expect_contains=[])])
    def rows(values): (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in values))
    # Root is unfinished, child and a different run in the root file have finals.
    rows([dict(type='reasoning',content='Planning'),dict(type='final',content='Other run',run_id='other-run')])
    c.run();t=c.result()['tests'][0];assert not t['pass'] and t['final']==''
    c.env['RUNNER_RC']='1';c.run(success=False);assert not c.result()['tests'][0]['pass']
    c.env['RUNNER_RC']='0';rows([dict(type='final',content='Root success')]);c.run()
    assert c.result()['tests'][0]['final']=='Root success'
    c.tests([dict(name='child-literal',prompt='Run the probe.',expect='final',expect_contains=['Child-only success'])])
    c.run();assert not c.result()['tests'][0]['pass']
    for key in ('NO_RUN_HANDSHAKE','AMBIGUOUS_ROOT','NO_TRAJECTORY'):
        c.env[key]='1';r=c.run(success=False);t=c.result()['tests'][0]
        assert r.returncode!=0 and not t['pass'] and 'harness_error' in t,key
        del c.env[key]
check('actual root handshake excludes nested and unrelated run evidence',root_selection)


def probe_isolation(kind):
    c=Case('probe-isolation-'+kind);live=c.root/'pretend-live';live.mkdir()
    paths=('MEM_DIR','TRAJ_DIR','SHELLM_TRAJ_DIR','HEADLONG_HOME','SHELLM_HOME','SHELLM_CONF_DIR','SHELLM_ENVS_DIR')
    for k in paths:
        d=live/k;d.mkdir();(d/'sentinel').write_text('unchanged');c.env[k]=str(d)
    c.env.update(IDENTITY_DIR=str(live),IDENTITY_NAME='synthetic-live',TRAJ_ID='caller',ROOT_TRAJ_ID='caller',
                 _SHELLM_PARENT_TRAJ_ID='caller',SHELLM_RUN_ID_OUT=str(live/'caller-handshake'))
    (c.skills/'probe'/'probe.py').write_text(
        'import os,pathlib\n'
        'for k in '+repr(paths)+':\n p=pathlib.Path(os.environ[k]);(p/"probe-wrote").write_text("synthetic")\n'
        'assert not any(os.environ.get(k) for k in ("IDENTITY_DIR","IDENTITY_NAME","TRAJ_ID","ROOT_TRAJ_ID","_SHELLM_PARENT_TRAJ_ID","SHELLM_RUN_ID_OUT"))\n'
        'print("".join(["Isolated", " probe executed"]))\n')
    if kind=='sh':
        (c.skills/'probe'/'SKILL.md').write_text('---\nname: probe\n---\nRun probe.sh\n')
        (c.skills/'probe'/'probe.sh').write_text('exec python3 "$(dirname "$0")/probe.py" "$@"\n')
    for cmd in ('pool','compile'):
        r=c.run(cmd)
        offered=json.loads(r.stdout) if cmd=='pool' else json.loads((c.cache/'pool-probe.json').read_text())['offered']
        assert 'Isolated probe executed' in offered
        assert sorted(str(p.relative_to(live)) for p in live.rglob('*') if p.is_file())==sorted(k+'/sentinel' for k in paths)
for kind in ('py','sh'):
    check(kind+' pool and compile probes isolate identity-selected state',lambda k=kind:probe_isolation(k))


def matching_and_missed():
    c=Case('matching-and-missed')
    c.tests([dict(name='case',prompt='Run the probe.',expect='final',expect_contains=['Hello','Hello world'])])
    c.output('hello world');c.run();assert c.result()['tests'][0]['pass']
check('word and phrase case matching are consistent',matching_and_missed)


def missing_json():
    c=Case('missing-json')
    missed=['a | b', 'quote " and \\ slash', 'line one\nline two']
    c.tests([dict(name='missing',prompt='Run the probe.',expect='final',expect_contains=missed)])
    c.run();assert c.result()['tests'][0]['expect_contains_missed']==missed
check('missing-literal JSON preserves pipes, quotes, backslashes and newlines',missing_json)


def cap_validation():
    c=Case('cap-validation')
    for name in ('SKILL_POOL_CAP','SKILL_POOL_SRC_CAP','SKILL_POOL_LIVE_CAP','SKILL_HARVEST_MAX_ENTRIES'):
        for value in ('abc','-1','2.5',''):
            c.env[name]=value;r=c.run('pool',success=False)
            assert r.returncode!=0 and name in r.stderr and 'nonnegative integer' in r.stderr,(name,value,r.stderr)
        for value in ('0','200 ',' 02 '):
            c.env[name]=value;c.run('pool')
        del c.env[name]
check('caps validate domain and name bad settings, accepting surrounding whitespace',cap_validation)


def teacher_failures():
    for mode in ('failure','empty','recover'):
        c=Case('teacher-'+mode)
        if mode=='empty': c.env['TEACHER_EMPTY']='1'
        else: c.env['TEACHER_FAILURES']='2' if mode=='recover' else '4'
        r=c.run(success=False)
        assert (r.returncode==0)==(mode=='recover'),r.stderr
        assert (c.root/'sleeps').read_text().splitlines()==(['5','10'] if mode=='recover' else ['5','10','15'])
        if mode!='recover': assert 'llm configured default' in r.stderr and not (c.root/'shell-prompt').exists()
    c=Case('teacher-invalid-json');(c.root/'tests.json').write_text('invalid')
    assert c.run(success=False).returncode!=0 and not (c.root/'shell-prompt').exists()
check('teacher retry recovery, final delay, empty/invalid responses and default diagnostic',teacher_failures)


def direct_cache():
    global SC
    original=SC;copy=ROOT/'direct-compiler';copy.mkdir()
    shutil.copyfile(SC,copy/'skill-compiler');cache=copy/'.compiled';cache.mkdir()
    sentinel=cache/'sentinel';sentinel.write_text('retain')
    try:
        SC=copy/'skill-compiler';c=Case('direct-cache');c.run()
        assert sentinel.read_text()=='retain' and c.cache.parent==c.root
    finally: SC=original
check('direct helper leaves sibling cache untouched',direct_cache)


# Third repair: actual configuration loaders, stopped before any provider call.
def operator_config():
    import shlex
    repo = Path(__file__).resolve().parents[1]
    originals = {name: (STUBS/name).read_text() for name in ('llm','shellm')}
    keys = ['OPENROUTER_API_KEY','OPENAI_API_KEY','SHELLM_MODEL','SHELLM_API_URL',
            'LLM_API_URL','LLM_API_KEY','LLM_PROVIDER','LLM_ADAPTER','LLM_OR_ONLY',
            'LLM_OR_ZDR','LLM_RETRIES','SHELLM_EFFORT']
    capture = ('import os,json; print(json.dumps({k:os.environ.get(k) for k in '
               + repr(keys+['TRAJ_DIR','LLM_USAGE_LEDGER']) + '}))')
    prefixes = {}
    for name, marker in [('llm','\nLLM_MODEL='), ('shellm','\nSHELLM_MAX_TOKENS=')]:
        source = (repo/'bin'/name).read_text()
        assert marker in source
        prefixes[name] = source[:source.index(marker)]
    impl = ROOT/'loader-impl'; impl.mkdir()
    try:
        for name in originals:
            (impl/name).write_text(originals[name])
            wrapper = ('#!/bin/bash\n'+shlex.quote(PYTHON)+' -c '+shlex.quote(capture)
                       + ' > "$CASE_ROOT/'+name+'-before-config.json"\n'
                       + prefixes[name] + '\nexport SHELLM_MODEL SHELLM_API_URL\n'
                       + shlex.quote(PYTHON) + ' -c ' + shlex.quote(capture)
                       + ' > "$CASE_ROOT/'+name+'-config.json"\n'
                       + 'exec '+shlex.quote(PYTHON)+' '+shlex.quote(str(impl/name))+' "$@"\n')
            (STUBS/name).write_text(wrapper)
        for mode in ('state','cwd','both','exported','empty','key-only','file-alias',
                     'export-alias','empty-alias','empty-shellm-alias','config-dir','cwd-selector','default-home','legacy-home','layered-values'):
            c=Case('config-'+mode)
            state=c.root/'state'
            if mode=='default-home':
                c.env.pop('HEADLONG_HOME');state=c.root/'home'/'.headlong'
            elif mode=='legacy-home':
                c.env.pop('HEADLONG_HOME');c.env['SHELLM_HOME']=str(state)
            state.mkdir()
            config=("OPENROUTER_API_KEY='dummy & \\\\ key'\nSHELLM_MODEL=synthetic-model\n"
                    "SHELLM_API_URL=https://synthetic.invalid/v1\nLLM_API_URL=https://other.invalid/v1\n"
                    "LLM_API_KEY=dummy-generic\nLLM_PROVIDER=openai-compatible\n"
                    "LLM_ADAPTER=/synthetic/adapter\nLLM_OR_ONLY=synthetic-host\n"
                    "LLM_OR_ZDR=true\nLLM_RETRIES=0\nSHELLM_EFFORT=low\n"
                    + 'TRAJ_DIR='+shlex.quote(str(c.root/'unused-live-traj'))+'\n'
                    + 'LLM_USAGE_LEDGER='+shlex.quote(str(c.root/'unused-ledger'))+'\n')
            if mode=='key-only': config='OPENAI_API_KEY=dummy-openai\n'
            if mode=='file-alias': config=config.replace('SHELLM_API_URL=https://synthetic.invalid/v1\n','')
            if mode in ('cwd','cwd-selector'):
                (c.root/'.env').write_text(config)
            else: (state/'.env').write_text(config)
            if mode=='layered-values':
                (c.root/'.env').write_text('PROVIDER_ENDPOINT=https://layered.invalid/v1\n')
                (state/'.env').write_text(config.replace('https://synthetic.invalid/v1', '$PROVIDER_ENDPOINT'))
            if mode=='both': (c.root/'.env').write_text('SHELLM_MODEL=cwd-model\nOPENROUTER_API_KEY=dummy-cwd\n')
            if mode=='exported':
                c.env.update(OPENROUTER_API_KEY='dummy-exported',SHELLM_MODEL='exported-model',
                             SHELLM_API_URL='https://exported.invalid/v1',LLM_OR_ONLY='exported-host')
            if mode=='empty': c.env.update(OPENROUTER_API_KEY='',SHELLM_MODEL='',LLM_PROVIDER='',LLM_OR_ONLY='')
            if mode=='export-alias': c.env['LLM_API_URL']='https://export-alias.invalid/v1'
            if mode=='empty-alias': c.env['LLM_API_URL']=''
            if mode=='empty-shellm-alias': c.env['SHELLM_API_URL']=''
            if mode in ('config-dir','cwd-selector'):
                conf=c.root/'config-dir';conf.mkdir();(conf/'.env').write_text(config.replace('synthetic-model','config-model'))
                if mode=='config-dir': c.env['SHELLM_CONF_DIR']=str(conf)
                else: (c.root/'.env').write_text('SHELLM_CONF_DIR='+shlex.quote(str(conf))+'\n')
            reference={}
            for name in originals:
                script=prefixes[name]+'\nexport SHELLM_MODEL SHELLM_API_URL\n'+shlex.quote(PYTHON)+' -c '+shlex.quote(capture)
                r=subprocess.run(['/bin/bash','-c',script],cwd=c.root,env=c.env,text=True,capture_output=True,check=True)
                reference[name]=json.loads(r.stdout)
            c.run()
            for name in originals:
                actual=json.loads((c.root/(name+'-config.json')).read_text())
                assert all(actual[k]==reference[name][k] for k in keys), (mode,name,'configuration differs from original loader')
                if name=='shellm':
                    assert Path(actual['TRAJ_DIR']).is_relative_to(c.root/'runs')
                    assert actual['LLM_USAGE_LEDGER'] is None
            if mode=='key-only':
                before=json.loads((c.root/'shellm-before-config.json').read_text())
                assert before['OPENROUTER_API_KEY'] is None and before['LLM_API_URL'] is None
                assert before['SHELLM_API_URL'] is None
            assert not (c.root/'unused-live-traj').exists() and not (c.root/'unused-ledger').exists()
            # No copied config or secret-bearing files remain in disposable runs.
            assert not list((c.root/'runs').rglob('.env'))
    finally:
        for name,source in originals.items(): (STUBS/name).write_text(source)
check('repair3 actual loader configuration and alias precedence',operator_config)


def obsidian_refusal():
    c=Case('obsidian-refusal');c.skill('obsidian','Synthetic vault test only.')
    vault=c.root/'vault';vault.mkdir();sentinel=vault/'sentinel';sentinel.write_text('untouched')
    c.env['OBSIDIAN_VAULT']=str(vault)
    for command in ('compile','pool'):
        r=c.run(command,skill='obsidian',success=False)
        assert r.returncode!=0 and 'skip-list' in r.stderr
    assert not (c.root/'teacher-count').exists() and not (c.root/'shell-prompt').exists()
    assert sentinel.read_text()=='untouched'
check('repair3 obsidian refused before probing or model calls',obsidian_refusal)


def documented_output(kind, json_output=False):
    c=Case('documented-'+kind+('-json' if json_output else ''));phrase='Canonical documented success'
    if json_output: phrase=json.dumps({'result': phrase})
    c.skill('probe','Run probe.py\n```text\n'+phrase+'\n```\n','print('+repr(phrase)+')\n')
    c.tests([dict(name='documented',prompt='Execute the probe.',expect=kind,expect_contains=[phrase])])
    row=dict(type=kind,**({'stdout':phrase,'exit':0} if kind=='shell-output' else {'content':phrase}))
    (c.root/'trajectory.jsonl').write_text(json.dumps(row)+'\n')
    c.run();assert c.result()['tests'][0]['verification']=='VERIFIED'
for kind in ('observation','shell-output','final'):
    check('repair3 documented '+kind+' remains evidence',lambda kind=kind:documented_output(kind))
    check('repair3 documented JSON '+kind+' remains evidence',lambda kind=kind:documented_output(kind,True))


def probe_children(mode):
    import signal
    import time
    c=Case('probe-child-'+mode)
    source=SC.read_text();helper=c.root/'bounded.sh'
    helper.write_text(source[source.index('_sc_bounded() {'):source.index('\nexecute_test() {')]+'\n_sc_bounded "$@"\n')
    child=c.root/'child.py';pidfile=c.root/'child-pid';parent_pid=c.root/'parent-pid'
    # The child publishes readiness itself. Its finite lifetime also bounds
    # cleanup if a broken helper or restricted test environment cannot signal it.
    child.write_text('import os,time,pathlib\npathlib.Path('+repr(str(pidfile))+').write_text(str(os.getpid()))\ntime.sleep(20)\n')
    parent=c.root/'parent.py'
    parent.write_text('import os,subprocess,sys,pathlib,time\n'
        'pathlib.Path('+repr(str(parent_pid))+').write_text(str(os.getpid()))\n'
        'subprocess.Popen([sys.executable,'+repr(str(child))+'])\n'
        'while not pathlib.Path('+repr(str(pidfile))+').exists(): time.sleep(.01)\n'
        + ('time.sleep(20)\n' if mode=='timeout' else ''))
    def running(pid):
        try: os.kill(pid,0)
        except ProcessLookupError: return False
        # Orphaned zombies may await container init reaping; they cannot run or
        # retain stdout. A denied inspection is a test failure, never a pass.
        status=subprocess.run(['/bin/ps','-p',str(pid),'-o','stat='],text=True,capture_output=True)
        if status.stderr.strip(): raise RuntimeError('process inspection unavailable: '+status.stderr.strip())
        return bool(status.stdout.strip()) and not status.stdout.lstrip().startswith('Z')
    try:
        # Generous outer limit still catches inherited-output pipes held by a
        # surviving descendant, without a subsecond interpreter-startup budget.
        r=subprocess.run([os.environ.get('SC_TEST_BASH','/bin/bash'),str(helper),'2',PYTHON,str(parent)],
                         env=c.env,text=True,capture_output=True,timeout=8)
        assert r.returncode==(124 if mode=='timeout' else 0),(r.returncode,r.stderr)
        assert pidfile.exists(),'child did not reach synchronized startup'
        pid=int(pidfile.read_text())
        deadline=time.monotonic()+2
        while running(pid) and time.monotonic()<deadline: time.sleep(.05)
        assert not running(pid),'probe descendant still running'
    finally:
        if parent_pid.exists():
            try: os.killpg(int(parent_pid.read_text()),signal.SIGKILL)
            except ProcessLookupError: pass
        if pidfile.exists():
            try: os.kill(int(pidfile.read_text()),signal.SIGKILL)
            except ProcessLookupError: pass
for mode in ('normal','timeout'):
    check('repair3 probe descendants bounded on '+mode,lambda mode=mode:probe_children(mode))


def option_validation():
    c=Case('option-validation')
    for opt in ('--skill','--teacher-model','--num-tests','--max-iterations'):
        r=c.run(extra=(opt,),success=False)
        assert r.returncode!=0 and 'requires a value' in r.stderr and 'unbound variable' not in r.stderr
    for opt in ('--num-tests','--max-iterations'):
        for val in ('0','-1','abc','1.5','','9223372036854775808'):
            r=c.run(extra=(opt,val),success=False)
            assert r.returncode!=0 and opt in r.stderr
    assert not (c.root/'teacher-count').exists()
    c.tests([dict(name='case'+str(i),prompt='Run.',expect='final',expect_contains=[]) for i in range(3)])
    c.run(extra=('--num-tests','01','--max-iterations','02'))
    assert len(c.result()['tests'])==1
check('repair3 options validate before calls and test count is a ceiling',option_validation)


def harvest_minimum():
    c=Case('harvest-minimum');td=c.root/'history';td.mkdir()
    rows=[dict(type='reasoning',run_id='a',cmd='python3 probe.py'),
          dict(type='shell-output',run_id='a',stdout='Historical diagnostic output')]
    (td/'events.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.env.update(SKILL_AUTO_HARVEST='1',SKILL_HARVEST_TRAJ_DIR=str(td),SKILL_HARVEST_MIN_COUNT='1')
    assert 'Historical diagnostic output' in json.loads(c.run('pool').stdout)
    c.env['SKILL_HARVEST_MIN_COUNT']='01'
    assert 'Historical diagnostic output' in json.loads(c.run('pool').stdout)
    for value in ('abc','','0','-1','1.5','9223372036854775808'):
        c.env['SKILL_HARVEST_MIN_COUNT']=value;r=c.run('pool',success=False)
        assert r.returncode!=0 and 'SKILL_HARVEST_MIN_COUNT' in r.stderr
check('repair3 history minimum diagnostic and valid history control',harvest_minimum)


def unchecked_literals():
    c=Case('unchecked-literals');c.output('Victory phrase stable','Victory phrase stable');c.env['RUNNER_RC']='1'
    c.run(success=False);r=c.result()['tests'][0]
    assert not r['pass'] and r['harness_error'] and r['expect_contains_missed']==[]
    assert r['expect_contains_unchecked']==['Victory phrase stable']
    del c.env['RUNNER_RC'];c.output('Different output','Different final');c.run();r=c.result()['tests'][0]
    assert r['expect_contains_missed']==['Victory phrase stable'] and r['expect_contains_unchecked']==[]
check('repair3 unchecked literals differ from checked misses',unchecked_literals)


def coarse_error_contract():
    c=Case('coarse-error');c.tests([dict(name='error',prompt='Verify probe rejects bad input.',expect='error',expect_contains=[])])
    rows=[dict(type='reasoning',cmd='ls missing'),dict(type='shell-output',exit=2,stderr='No such file'),
          dict(type='reasoning',cmd='python3 probe.py'),dict(type='shell-output',exit=0,stdout='Victory phrase stable')]
    (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.run();assert c.result()['tests'][0]['verification']=='GREEN-NO-LITERALS'
    c.env['RUNNER_RC']='1';c.run(success=False);assert not c.result()['tests'][0]['pass']
check('repair3 coarse error contract is not behavioral verification or runner failure',coarse_error_contract)


def cache_commands():
    c=Case('cache-commands')
    # Case.run supplies --skill even to list; invoke the documented list form here.
    def listing():
        return subprocess.run([os.environ.get('SC_TEST_BASH','/bin/bash'),str(SC),'list'],env=c.env,cwd=c.root,
                              text=True,capture_output=True,check=True).stdout
    assert listing().strip()=='No compiled skills'
    c.run();assert listing().splitlines()==['probe']
    sentinel=c.root/'outside.md';sentinel.write_text('untouched')
    for command in ('show','clean'):
        for name in ('../outside','/outside','probe/../outside'):
            r=c.run(command,skill=name,success=False)
            assert r.returncode!=0 and 'invalid skill name' in r.stderr
        r=c.run(command,extra=('--skill',),success=False)
        assert r.returncode!=0 and 'requires a value' in r.stderr
    assert sentinel.read_text()=='untouched'
    c.run('show');c.run('clean');assert listing().strip()=='No compiled skills'
check('repair3 list and invalid show clean names',cache_commands)


def command_echo():
    c=Case('command-echo');phrase='echo Victory phrase stable'
    c.tests([dict(name='echo',prompt='Execute the probe.',expect='shell-output',expect_contains=[phrase])])
    rows=[dict(type='reasoning',cmd=phrase),dict(type='shell-output',stdout=phrase,exit=0)]
    (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.run();assert not c.result()['tests'][0]['pass']
check('repair3 recorded command echo is not assertion evidence',command_echo)


# Fourth repair: invocation-local provenance and actual rc-loader isolation.
def selector_isolation(mode):
    import shlex
    c=Case('selectors-'+mode);live=c.root/'pretend-live';live.mkdir()
    keys=('CHATRC','SKILLSRC','THINKERS_DIR','SHELLM_BROKER_DIR')
    marker=live/'rc-sourced'
    rc='printf touched > '+shlex.quote(str(marker))+'\n'
    (c.root/'.skillsrc').write_text(rc)
    (live/'skillsrc').write_text(rc)
    (live/'chatrc').write_text('default_send_from=pretend-live\n')
    for k in ('THINKERS_DIR','SHELLM_BROKER_DIR'): (live/k).mkdir()
    c.env.update(CHATRC=str(live/'chatrc'),THINKERS_DIR=str(live/'THINKERS_DIR'),
                 SHELLM_BROKER_DIR=str(live/'SHELLM_BROKER_DIR'),SC_KEEP_RUNS='1')
    if mode=='explicit': c.env['SKILLSRC']=str(live/'skillsrc')
    original=(STUBS/'skills').read_text()
    loader=Path(__file__).resolve().parents[1]/'bin'/'skills'
    capture=('import os,json,pathlib; p=pathlib.Path(os.environ["CASE_ROOT"])/"loader-calls.jsonl"; '
             'p.open("a").write(json.dumps(dict(cwd=os.getcwd(),rc=os.environ.get("SKILLSRC")))+"\\n")')
    (STUBS/'skills').write_text('#!/bin/bash\n'+shlex.quote(PYTHON)+' -c '+shlex.quote(capture)
                               +'\nexec /bin/bash '+shlex.quote(str(loader))+' "$@"\n')
    try: c.run()
    finally: (STUBS/'skills').write_text(original)
    assert not marker.exists(),'caller rc consumed by actual skills loader'
    calls=[json.loads(x) for x in (c.root/'loader-calls.jsonl').read_text().splitlines()]
    assert calls and '## Skills' in (c.root/'shell-prompt').read_text()
    for call in calls:
        assert Path(call['cwd']).is_relative_to(c.root/'runs')
        assert Path(call['rc']).is_relative_to(Path(call['cwd']))
        assert Path(call['rc']).read_text()==''
    actual=json.loads((c.root/'runner-selectors.json').read_text())
    for key in keys:
        assert Path(actual[key]).is_relative_to(c.root/'runs'),key
        path=Path(actual[key])
        if key.endswith('RC'): assert path.read_text()==''
        else: assert path.is_dir()
for mode in ('explicit','fallback'):
    check('repair4 actual skills loader '+mode+' rc and runner selectors',lambda mode=mode:selector_isolation(mode))


def probe_selectors():
    c=Case('probe-selectors');live=c.root/'pretend-live';live.mkdir()
    keys=('CHATRC','SKILLSRC','THINKERS_DIR','SHELLM_BROKER_DIR')
    for key in keys:
        p=live/key
        if key.endswith('RC'): p.write_text('sentinel')
        else: p.mkdir();(p/'sentinel').write_text('sentinel')
        c.env[key]=str(p)
    (c.skills/'probe'/'probe.py').write_text(
        'import os,pathlib\nfor key in '+repr(keys)+':\n'
        ' p=pathlib.Path(os.environ[key])\n assert not p.is_relative_to(pathlib.Path('+repr(str(live))+'))\n'
        ' if key.endswith("RC"): assert p.read_text()==""\n else: assert p.is_dir()\n'
        'print("".join(["Controlled", " selector probe"]))\n')
    assert 'Controlled selector probe' in json.loads(c.run('pool').stdout)
    for key in keys:
        p=live/key
        assert (p if key.endswith('RC') else p/'sentinel').read_text()=='sentinel'
check('repair4 pool probe redirects omitted selectors',probe_selectors)


def immutable_pool(mode):
    c=Case('pool-snapshot-'+mode);c.env['SKILL_POOL_CAP']='1'
    phrase='Dropped unique diagnostic'
    c.skill('probe','Run probe.py.\n','print("Offered unique diagnostic")\nprint("'+phrase+'")\n')
    c.tests([dict(name='dropped',prompt='Execute probe.',expect='shell-output',expect_contains=[phrase])])
    c.output(phrase);c.env['MUTATE_POOL']=mode;c.run()
    t=c.result()['tests'][0]
    assert t['literal_labels'][phrase]=='POOL-DROPPED',t
    assert t['verification']=='GREEN-ON-DROPPED' and c.result()['summary']['pool_truncated']
    assert (c.root/'pool-before-mutation.json').exists()
for mode in ('remove','replace'):
    check('repair4 pool snapshot survives shared cache '+mode,lambda mode=mode:immutable_pool(mode))


def blank_literals():
    for i,lit in enumerate(('', ' ', '   ', '\t', '\n', '\t \n')):
        c=Case('blank-'+str(i));c.tests([dict(name='blank',prompt='Run.',expect='final',expect_contains=[lit])])
        r=c.run(success=False)
        assert r.returncode!=0 and 'invalid test cases' in r.stderr
        assert not (c.root/'shell-prompt').exists()
    c=Case('empty-list');c.tests([dict(name='none',prompt='Run.',expect='final',expect_contains=[])])
    c.run();assert c.result()['tests'][0]['verification']=='GREEN-NO-LITERALS'
    for i,lit in enumerate(('  Victory phrase stable  ', '\tVictory phrase stable\t', 'Victory\nphrase stable')):
        c=Case('nonblank-'+str(i));c.tests([dict(name='nonblank',prompt='Run.',expect='final',expect_contains=[lit])])
        if '\n' not in lit: c.output(lit)
        c.run();assert c.result()['tests'][0]['test']['expect_contains']==[lit]
        if '\n' not in lit: assert c.result()['tests'][0]['pass']
check('repair4 reject all blank literals but preserve nonblank bytes and empty lists',blank_literals)


def bracketed_prose():
    for i,prefix in enumerate(('Here are [3] cases:','Here are [some] cases:',
                               '[{"name":"wrong schema"}]\n', '```json\n')):
        c=Case('bracketed-'+str(i));p=c.root/'tests.json';p.write_text(prefix+p.read_text()+'\n```')
        c.run();assert c.result()['tests'][0]['pass']
    c=Case('invalid-candidates');(c.root/'tests.json').write_text('[] [3] [{"name":"incomplete"}]')
    assert c.run(success=False).returncode!=0 and not (c.root/'shell-prompt').exists()
check('repair4 find schema-valid arrays after bracketed prose, reject invalid candidates',bracketed_prose)


def retained_locations():
    c=Case('retained-locations');c.env['SC_KEEP_RUNS']='1';r=c.run()
    runs=[p for p in (c.root/'runs').iterdir() if p.is_dir()]
    assert runs and all('Retained run: '+str(p) in r.stderr for p in runs)
    assert 'Retained scratch:' in r.stderr
check('repair4 retained run paths printed with custom runs base',retained_locations)


def frontmatter_contract():
    c=Case('frontmatter-contract');p=c.skills/'probe'/'SKILL.md'
    p.write_text('--- \t\nname: probe\ndescription: MetadataUniqueToken\n---\t \nBody `BodyUniqueToken`.\n')
    c.tests([dict(name='metadata',prompt='Describe the skill.',expect='final',expect_contains=['MetadataUniqueToken'])])
    c.output('MetadataUniqueToken');c.run();t=c.result()['tests'][0]
    assert t['literal_sources']['MetadataUniqueToken']=='METADATA',t
    assert t['literal_labels']['MetadataUniqueToken']=='POOL-EXACT',t
    assert '"description":"MetadataUniqueToken"' in (c.root/'teacher-prompt').read_text()
check('repair4 frontmatter delimiters agree for spec, pool and provenance',frontmatter_contract)


def dependency_metadata():
    c=Case('dependency-metadata');d=c.skills/'skill-compiler';d.mkdir()
    repo=Path(__file__).resolve().parents[1]
    shutil.copyfile(repo/'contrib'/'skill-compiler'/'SKILL.md',d/'SKILL.md')
    c.env['SKILLSRC']=str(c.root/'empty-rc');Path(c.env['SKILLSRC']).write_text('')
    r=subprocess.run(['/bin/bash',str(repo/'bin'/'skills'),'show','skill-compiler','--requires'],
                     env=c.env,cwd=c.root,text=True,capture_output=True,check=True)
    assert json.loads(r.stdout)['requires']['bins']==['bash','python3','jq','llm','shellm','skills']
check('repair4 dependency metadata uses actual loader spelling',dependency_metadata)


# Sixth repair: literal bytes survive extraction and multiline evidence filtering.
def newline_case(c, literal, output, want, prompt='Execute the probe.', rows=None):
    c.tests([dict(name='newline',prompt=prompt,expect='shell-output',expect_contains=[literal])])
    if rows is None: rows=[dict(type='shell-output',stdout=output,exit=0)]
    (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.run();t=c.result()['tests'][0]
    assert t['test']['expect_contains']==[literal]
    assert t['pass'] is want,(literal,output,t)
    assert t['expect_contains_matched']==int(want)
    assert t['expect_contains_missed']==([] if want else [literal])
    assert t['expect_contains_unchecked']==[]


def trailing_newlines():
    c=Case('trailing-newlines')
    for literal,output,want in [
        ('Victory phrase stable\n','Victory phrase stableSuffix',False),
        ('Victory phrase stable\n','Victory phrase stable',False),
        ('Victory phrase stable\n','Victory phrase stable\n',True),
        ('Victory phrase stable\n\n','Victory phrase stable',False),
        ('Victory phrase stable\n\n','Victory phrase stable\n',False),
        ('Victory phrase stable\n\n','Victory phrase stable\n\n',True),
        ('Victory\n','Victories\n',False),
    ]: newline_case(c,literal,output,want)
check('repair6 trailing newlines require line boundaries and preserve blank lines',trailing_newlines)


def newline_missed_bytes():
    c=Case('newline-missed-bytes')
    missed=['Missing assertion\n', 'Missing | "quote" \\ slash\t\n\n']
    literals=['Victory phrase stable']+missed
    c.tests([dict(name='missed',prompt='Execute the probe.',expect='final',expect_contains=literals)])
    c.run();t=c.result()['tests'][0]
    assert not t['pass'] and t['expect_contains_matched']==1
    assert t['test']['expect_contains']==literals
    assert t['expect_contains_missed']==missed and t['expect_contains_unchecked']==[]
check('repair6 missed literals retain every trailing newline and other byte',newline_missed_bytes)


def multiline_literals():
    c=Case('multiline-literals')
    for literal,output,want in [
        ('Alpha\nOmega','Alpha\nOmega',True),
        ('Victory\nphrase stable','Victory\nphrase stable',True),
        ('Alpha\nOmega','Alpha Omega',False),
        ('Alpha\nOmega','Alpha\n\nOmega',False),
        ('5 tests passed\nDone','15 tests passed\nDone',False),
        ('5 tests passed\nDone','5 tests passed\nDone',True),
        ('Alpha\n5','Alpha\n15',False),
        ('Alpha\n5','Alpha\n51',False),
        ('Alpha\n5','alpha\n5',True),
    ]: newline_case(c,literal,output,want)
    # Separately recorded fields are not a single contiguous multiline output.
    newline_case(c,'Alpha\nOmega','',False,rows=[dict(type='shell-output',stdout='Alpha',stderr='Omega',exit=0)])
    newline_case(c,'Alpha\nOmega','',False,rows=[dict(type='shell-output',stdout='Alpha',exit=0),dict(type='final',content='Omega')])
check('repair6 multiline literals match contiguous output with digit boundaries',multiline_literals)


def multiline_exclusions():
    c=Case('multiline-exclusions')
    newline_case(c,'Alpha\nOmega','Alpha\nNo failures\nOmega',False)
    newline_case(c,'Alpha\nOmega','Alpha\nEcho marker\nOmega',False,prompt='Echo marker')
    newline_case(c,'Alpha\nOmega','Alpha\n{"fixture":"synthetic"}\nOmega',False,
                 rows=[dict(type='reasoning',cmd='{"fixture":"synthetic"}'),dict(type='shell-output',stdout='Alpha\n{"fixture":"synthetic"}\nOmega',exit=0)])
    (c.root/'fixture.txt').write_text('{"fixture":"synthetic"}\n')
    newline_case(c,'Alpha\nOmega','Alpha\n{"fixture":"synthetic"}\nOmega',False)
    (c.root/'fixture.txt').unlink()
    newline_case(c,'violations\nfound','No violations\nfound',False)
    newline_case(c,'No violations\nNo errors','No violations\nNo errors',True)
    newline_case(c,'No violations\nSummary complete','No violations\nSummary complete',True)
    newline_case(c,'Summary complete\nNo violations','Summary complete\nNo violations',True)
    newline_case(c,'No violations\n','Status: No violations',False)
    newline_case(c,'No violations\n','Status: No violations\n',True)
    newline_case(c,'Alpha\nAlpha','No Alpha\nAlpha\nAlpha',True)

    newline_case(c,'Alpha\nOmega','Alpha\nNo failures\nOmega\nAlpha\nOmega',True)
check('repair6 multiline matching cannot bridge echo or denial exclusions',multiline_exclusions)


def multiline_quotes():
    c=Case('multiline-quotes')
    newline_case(c,"quote 'term'\n",'quote "term"Suffix',False)
    newline_case(c,"quote 'term'\n",'quote "term"',False)
    newline_case(c,"quote 'term'\n",'quote "term"\n',True)
    newline_case(c,"quote 'term'\nNext line",'quote "term"\nNext line',True)
check('repair6 quote folding retains multiline literal boundaries',multiline_quotes)


def multiline_fields():
    c=Case('multiline-fields');literal='Alpha\nOmega\n'
    for row in [dict(type='shell-output',stdout=literal,exit=0),
                dict(type='shell-output',stdout=None,content=literal,exit=0),
                dict(type='shell-output',stderr=literal,exit=0),
                dict(type='observation',content=literal),
                dict(type='final',content=literal),
                dict(type='final',content=None,details=literal)]:
        # A named shell-output establishes the outcome; all recorded output
        # kinds remain eligible for literal evidence, just as for single lines.
        newline_case(c,literal,'',True,rows=[dict(type='shell-output',stdout='Unrelated output',exit=0),row])
check('repair6 multiline evidence keeps observed field and fallback semantics',multiline_fields)



# Coordinator follow-up: CRLF echoes must remain excluded without normalizing
# the literal or inventing an output newline.
def multiline_recorded_bytes():
    c=Case('multiline-recorded-bytes')
    newline_case(c,'Alpha\r\nEcho marker\r\nOmega','Alpha\r\nEcho marker\r\nOmega',False,prompt='Echo marker')
    newline_case(c,'Alpha\r\nOmega','Alpha\r\nOmega',True)
    newline_case(c,'Alpha\nOmega','Alpha\r\nOmega',False)
    newline_case(c,'Alpha\nOmega\n','Alpha\nOmega',False)
    newline_case(c,'Alpha\nOmega\n','Alpha\nOmega\n',True)
    newline_case(c,'Alpha\r\nEcho marker\r\nOmega','',False,rows=[dict(type='reasoning',cmd='Echo marker'),dict(type='shell-output',stdout='Alpha\r\nEcho marker\r\nOmega',exit=0)])
    newline_case(c,'violations\r\nfound','No violations\r\nfound',False)
check('coordinator multiline matching preserves recorded bytes and excludes CRLF echoes',multiline_recorded_bytes)

def history_concurrency(stage):
    """Pause real tool boundaries; let B replace shared history before A resumes."""
    import signal
    import time

    a=Case('history-race-'+stage+'-a'); b=Case('history-race-'+stage+'-b')
    shared=ROOT/('history-race-'+stage+'-cache')
    phrases=('Alpha owned historical phrase', 'Beta owned historical phrase')
    for c, phrase in zip((a,b), phrases):
        td=c.root/'history';td.mkdir()
        rows=[dict(type='reasoning',run_id='fixture',cmd='python3 probe.py'),
              dict(type='shell-output',run_id='fixture',stdout=phrase)]
        (td/'events.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        c.env.update(SKILL_AUTO_HARVEST='1',SKILL_HARVEST_TRAJ_DIR=str(td),
                     SKILL_HARVEST_MIN_COUNT='1',SKILL_HARVEST_CACHE=str(shared))
    # A's result exercises occurrence provenance as well as the teacher's pool.
    a.tests([dict(name='history',prompt='Run the probe.',expect='final',
                  expect_contains=list(phrases))])
    a.output('\n'.join(phrases))
    if stage=='cached':
        a.run('pool')  # Seed a valid reusable A cache before the overlap.

    wrapped=a.root/'barrier-tools';wrapped.mkdir()
    # These launchers still execute the actual Python/jq code. Only A pauses,
    # once, at the chosen handoff. No compiler test hooks or fabricated results.
    barrier=r'''import os, pathlib, subprocess, sys, time
name=pathlib.Path(sys.argv[0]).name
root=pathlib.Path(os.environ['CASE_ROOT'])
stage=os.environ['HISTORY_RACE_STAGE']
harvest=name=='python3' and 'SKILL_HARVEST_FILES' in os.environ
cached=name=='jq' and any('.schema == 2 and .skill_path' in x for x in sys.argv)
provenance=name=='python3' and 'results_json_file' in os.environ
selected=(stage in ('input','published') and harvest or stage=='cached' and cached
          or stage=='provenance' and provenance)
if selected and not (root/'barrier-ready').exists():
    tool=os.environ['REAL_PYTHON' if name=='python3' else 'REAL_JQ']
    if stage in ('published','cached'):
        rc=subprocess.run([tool]+sys.argv[1:]).returncode
        if rc: sys.exit(rc)
    (root/'barrier-ready').write_text(stage)
    deadline=time.monotonic()+45
    while not (root/'barrier-release').exists():
        if time.monotonic()>deadline: raise SystemExit('history barrier timed out')
        time.sleep(.02)
    if stage in ('published','cached'): sys.exit(0)
'''
    for name in ('python3','jq'):
        p=wrapped/name;p.write_text('#!'+PYTHON+'\n'+barrier+STUB);p.chmod(0o755)
    a.env.update(PATH=str(wrapped)+os.pathsep+a.env['PATH'],HISTORY_RACE_STAGE=stage)
    bash=os.environ.get('SC_TEST_BASH','/bin/bash' if sys.platform=='darwin' else 'bash')
    children=[]

    def start(c, command):
        # Own the whole compiler group, including launchers blocked at barriers.
        out=(c.root/'concurrent.stdout').open('w');err=(c.root/'concurrent.stderr').open('w')
        try:
            p=subprocess.Popen([bash,str(SC),command,'--skill','probe'],env=c.env,
                               cwd=c.root,stdout=out,stderr=err,start_new_session=True)
        finally:
            out.close();err.close()
        children.append(p)
        return p

    try:
        pa=start(a,'compile')
        deadline=time.monotonic()+30
        while not (a.root/'barrier-ready').exists():
            assert pa.poll() is None, (a.root/'concurrent.stderr').read_text()
            assert time.monotonic()<deadline, 'A did not reach '+stage+' barrier'
            time.sleep(.02)
        pb=start(b,'pool')
        assert pb.wait(timeout=30)==0, (b.root/'concurrent.stderr').read_text()
        bpool=json.loads((b.root/'concurrent.stdout').read_text())
        assert phrases[1] in bpool and phrases[0] not in bpool, bpool
        blob=json.loads((shared/'pool-history-probe.json').read_text())
        assert blob['skill_path']==str(b.skills/'probe') and blob['traj_path']==str(b.root/'history')
        assert [r['line'] for r in blob['entries']]==[phrases[1]], blob
        (a.root/'barrier-release').touch()
        assert pa.wait(timeout=45)==0, (a.root/'concurrent.stderr').read_text()
        prompt=(a.root/'teacher-prompt').read_text()
        result=a.result()['tests'][0]
        # Record both claims before asserting, so negative baselines show which
        # handoff failed even when the later provenance harvest repaired itself.
        evidence=dict(stage=stage,teacher_alpha=phrases[0] in prompt,
                      teacher_beta=phrases[1] in prompt,result=result)
        (a.root/'race-evidence.json').write_text(json.dumps(evidence,indent=2))
        assert evidence['teacher_alpha'] and not evidence['teacher_beta'], evidence
        assert result['pass'] is True, result
        assert result['literal_sources'][phrases[0]]=='TOOL-OUTPUT', result
        assert result['literal_sources'][phrases[1]]!='TOOL-OUTPUT', result
        assert result['literal_labels'][phrases[0]]=='POOL-EXACT', result
        assert result['literal_labels'][phrases[1]]=='INVENTED', result
    finally:
        (a.root/'barrier-release').touch()
        for p in children:
            try: os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            p.wait(timeout=5)

for stage in ('input','published','cached','provenance'):
    check('history concurrency '+stage,lambda stage=stage:history_concurrency(stage))

def history_unavailable_cache():
    c=Case('history-unavailable-cache');td=c.root/'history';td.mkdir()
    phrase='Private harvest survives unavailable publication'
    rows=[dict(type='reasoning',run_id='fixture',cmd='python3 probe.py'),
          dict(type='shell-output',run_id='fixture',stdout=phrase)]
    (td/'events.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    unavailable=c.root/'not-a-directory';unavailable.write_text('untouched')
    c.env.update(SKILL_AUTO_HARVEST='1',SKILL_HARVEST_TRAJ_DIR=str(td),
                 SKILL_HARVEST_MIN_COUNT='1',SKILL_HARVEST_CACHE=str(unavailable))
    c.tests([dict(name='history',prompt='Run the probe.',expect='final',expect_contains=[phrase])])
    c.output(phrase);c.run()
    assert phrase in (c.root/'teacher-prompt').read_text()
    result=c.result()['tests'][0]
    assert result['pass'] is True and result['literal_sources'][phrase]=='TOOL-OUTPUT', result
    assert unavailable.read_text()=='untouched'
check('history concurrency publication is optional',history_unavailable_cache)

def nul_teacher(field, value, suffix):
    c=Case('nul-teacher-'+suffix)
    case=dict(name='probe',prompt='Run the probe.',expect='final',
              expect_contains=['Victory phrase stable'])
    case[field]=[value] if field=='expect_contains' else value
    c.tests([case]);r=c.run(success=False)
    assert r.returncode!=0 and 'NUL' in r.stderr, (r.returncode,r.stderr[-300:])
    assert not (c.root/'runner-selectors.json').exists()
    assert not (c.root/'shell-prompt').exists()
    assert not (c.cache/'probe.json').exists() and not (c.cache/'probe.md').exists()
for suffix, value in [('start','\0Victory phrase stable'),
                      ('middle','Victory phrase\0 stable'),
                      ('end','Victory phrase stable\0'),('only','\0')]:
    check('NUL boundary teacher literal '+suffix,
          lambda value=value,suffix=suffix:nul_teacher('expect_contains',value,suffix))
for field in ('name','prompt'):
    check('NUL boundary teacher '+field,
          lambda field=field:nul_teacher(field,'Run\0probe',field))


def nul_evidence(kind, field, multiline=False):
    c=Case('nul-evidence-'+kind+'-'+field+('-multiline' if multiline else ''))
    c.env['SC_KEEP_RUNS']='1'
    literal='Victory phrase stable\nNext line\r\n' if multiline else 'Victory phrase stable'
    c.tests([dict(name='before',prompt='Run the probe.',expect='final',expect_contains=[literal]),
             dict(name='binary',prompt='Run the probe.',expect='final',expect_contains=[literal])])
    good=[dict(type='shell-output',stdout=literal),dict(type='final',content='Reported.')]
    # The first case succeeds. Only the second runner writes binary evidence.
    bad=[dict(type=kind,**{field:literal.replace('phrase','phrase\0')}),
         dict(type='final',content='Reported.')]
    wrapper=c.root/'runner';wrapper.mkdir()
    prefix='''import json, os, pathlib
root=pathlib.Path(os.environ['CASE_ROOT'])
counter=root/'runner-count'
n=int(counter.read_text())+1 if counter.exists() else 1
counter.write_text(str(n))
rows=json.loads((root/('good.json' if n==1 else 'bad.json')).read_text())
(root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\\n' for r in rows))
'''
    (c.root/'good.json').write_text(json.dumps(good))
    (c.root/'bad.json').write_text(json.dumps(bad))
    stub=wrapper/'shellm';stub.write_text('#!'+PYTHON+'\n'+prefix+STUB);stub.chmod(0o755)
    c.env['PATH']=str(wrapper)+os.pathsep+c.env['PATH']
    r=c.run(success=False);results=c.result()['tests']
    assert r.returncode!=0, 'binary evidence silently accepted'
    assert len(results)==2 and results[0]['pass'] is True, results
    t=results[1]
    assert t['pass'] is False and 'NUL' in t['harness_error'], t
    assert t['expect_contains_unchecked']==[literal] and t['expect_contains_missed']==[],t
    assert t['expect_contains_matched']==0 and t['verification']!='VERIFIED',t
    raw=list((c.root/'runs').rglob('trajectory.jsonl'))
    assert any(any('\0' in str(row.get(field,'')) for row in
                   [json.loads(line) for line in p.read_text().splitlines()]) for p in raw), raw
for kind, field in [('shell-output','stdout'),('shell-output','stderr'),
                    ('shell-output','content'),('final','content'),('final','details'),
                    ('observation','content'),('observation','details'),('reasoning','cmd')]:
    check('NUL boundary evidence '+kind+' '+field,
          lambda kind=kind,field=field:nul_evidence(kind,field))
check('NUL boundary evidence multiline',lambda:nul_evidence('observation','content',True))


def nul_supported_controls():
    c=Case('nul-supported-controls')
    literal='Café 漢字\nNext line\r\n'
    cases=[dict(name='Café 漢字',prompt='Run the probe.\r\n',expect='shell-output',expect_contains=[literal]),
           dict(name='no literals',prompt='Run the probe.',expect='final',expect_contains=[])]
    invalid=[dict(name='bad\0name',prompt='Run.',expect='final',expect_contains=[])]
    (c.root/'tests.json').write_text('Unrelated [prose] '+json.dumps(invalid)+'\n'+json.dumps(cases))
    c.output(literal)
    # A different run's binary row is not selected evidence.
    with (c.root/'trajectory.jsonl').open('a') as f:
        f.write(json.dumps(dict(type='final',content='other\0run',run_id='unrelated'))+'\n')
    c.run();results=c.result()['tests']
    assert len(results)==2 and all(t['pass'] for t in results),results
    assert [t['test'] for t in results]==cases,results
check('NUL boundary supported controls and later valid array',nul_supported_controls)

def probe_temp_failure():
    for command in ('pool', 'compile'):
        c=Case('probe-temp-failure-'+command)
        (c.skills/'probe'/'probe.py').write_text(
            'import os, pathlib\npathlib.Path(os.environ["CASE_ROOT"], "probe-executed").touch()\n')
        wrapper=c.root/'temp-wrapper';wrapper.mkdir()
        stub=wrapper/'mktemp'
        stub.write_text('#!'+PYTHON+'\nimport os, sys\n'
                        'if "-d" in sys.argv and (len(sys.argv)==2 or "phrase-pool." in sys.argv[-1]): sys.exit(1)\n'
                        'os.execv('+repr(shutil.which('mktemp'))+', ["mktemp"]+sys.argv[1:])\n')
        stub.chmod(0o755)
        c.env['PATH']=str(wrapper)+os.pathsep+c.env['PATH']
        r=c.run(command, success=False)
        assert r.returncode != 0, r.stdout
        assert not (c.root/'probe-executed').exists()
        assert not (c.root/'teacher-count').exists()
        assert not (c.cache/'probe.json').exists()
check('probe temporary directory failure stops before execution',probe_temp_failure)

print(f'{count-failed} regression checks passed, {failed} failed',flush=True)
sys.exit(bool(failed))
