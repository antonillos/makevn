import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import hashlib
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
spec = importlib.util.spec_from_file_location('scoped', ROOT / 'libexec/makevn/common/scoped_coverage.py')
scoped = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scoped)


class ScopedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'base'], check=True)
        self.state = self.repo / '.makevn/state/focused-coverage'
        self.source = 'client/src/main/java/example/Owner.java'
        path = self.repo / self.source
        path.parent.mkdir(parents=True)
        path.write_text('class Owner {}')
        self.compiled = self.repo / 'client/target/classes/example/Owner.class'
        self.compiled.parent.mkdir(parents=True)
        self.compiled.write_bytes(b'bytecode')
        self.ut = self.repo / 'client/target/jacoco.exec'
        self.it = self.repo / 'boot/target/classes/boot.coverage'
        self.it.parent.mkdir(parents=True)
        self.ut.write_bytes(b'old UT')
        self.it.write_bytes(b'old IT')

    def test_preparation_fixture_changes_are_tested_from_new_baseline(self):
        (self.repo / 'pom.xml').write_text('<project><packaging>pom</packaging><modules><module>client</module><module>boot</module></modules></project>')
        for owner in ['client', 'boot']:
            (self.repo / owner / 'pom.xml').write_text('<project/>')
        fixture = self.repo / 'src/test/resources/shared/schema.avsc'
        fixture.parent.mkdir(parents=True)
        fixture.write_text('before')
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [])
        fixture.write_text('generated')
        plan = 'client\t*\nboot\t*'
        with self.assertRaisesRegex(ValueError, 'schema.avsc'):
            scoped.checkpoint(self.repo, self.state, 'client\t*\nboot\texample.Test')
        with self.assertRaisesRegex(ValueError, 'verify-changes-preview.*Missing complete suites: boot'):
            scoped.checkpoint(self.repo, self.state, 'client\t*\nboot\texample.Test')
        self.ut.write_bytes(b'preparation data')
        scoped.checkpoint(self.repo, self.state, plan)
        self.assertFalse(self.ut.exists())
        scoped.finish(self.repo, self.state)
        scoped.load(self.repo, self.state)
        fixture.write_text('during tests')
        with self.assertRaisesRegex(ValueError, 'schema.avsc'):
            scoped.finish(self.repo, self.state)

    def test_checkpoint_blocks_config_edits_and_duplicate_checkpoint(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [])
        config = self.repo / '.makevn/config'
        config.write_text('changed')
        with self.assertRaisesRegex(ValueError, '.makevn/config'):
            scoped.checkpoint(self.repo, self.state, 'client\t*\nboot\t*')
        config.unlink()
        scoped.checkpoint(self.repo, self.state, 'client\t*\nboot\t*')
        with self.assertRaisesRegex(ValueError, 'Invalid focused'):
            scoped.checkpoint(self.repo, self.state, 'client\t*\nboot\t*')

    def test_checkpoint_rejects_source_edits_and_partial_suites(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [])
        (self.repo / self.source).write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Owner.java'):
            scoped.checkpoint(self.repo, self.state, 'client\t*\nboot\t*')

    def ready(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        self.ut.write_bytes(b'new UT')
        self.it.write_bytes(b'new IT')
        scoped.finish(self.repo, self.state)
        return scoped.load(self.repo, self.state)

    def test_snapshot_merges_owners_and_excludes_old_append_data(self):
        manifest = self.ready()
        self.assertEqual({Path(p).read_bytes() for p in manifest['data']}, {b'new UT', b'new IT'})
        self.assertEqual(self.ut.with_name('jacoco.exec.before-focused').read_bytes(), b'old UT')
        self.ut.write_bytes(b'other execution')
        scoped.load(self.repo, self.state)  # Independent snapshot.
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        with self.assertRaisesRegex(ValueError, 'last verification did not complete successfully.*verify-changes-\\*.log'):
            scoped.load(self.repo, self.state)

    def test_root_module_changed_class_is_snapshotted(self):
        source = 'src/main/java/example/Root.java'
        source_path = self.repo / source
        source_path.parent.mkdir(parents=True)
        source_path.write_text('class Root {}')
        compiled = self.repo / 'target/classes/example/Root.class'
        compiled.parent.mkdir(parents=True)
        compiled.write_bytes(b'root bytecode')
        scoped.prepare(self.repo, self.state, self.repo, ['.'], [source])
        data = self.repo / 'target/jacoco.exec'
        data.write_bytes(b'fresh coverage')
        scoped.finish(self.repo, self.state)
        manifest = scoped.load(self.repo, self.state)
        self.assertEqual(manifest['class_owners'], {'example/Root': '.'})
        self.assertEqual((Path(manifest['classes']) / 'example/Root.class').read_bytes(), b'root bytecode')

    def test_source_and_snapshot_changes_reject_stale_evidence(self):
        manifest = self.ready()
        path = self.repo / self.source
        path.write_text('class Changed {}')
        with self.assertRaisesRegex(ValueError, 'sources/config changed'):
            scoped.load(self.repo, self.state)
        path.write_text('class Owner {}')
        Path(manifest['data'][0]).write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            scoped.load(self.repo, self.state)

    def test_legacy_config_is_not_authoritative_but_shared_inputs_are_hashed(self):
        config = self.repo / 'makevn-impact.json'
        config.write_text(json.dumps({'version': 1, 'sharedResources': [{'path': 'src/test/resources/shared', 'modules': ['client'], 'externalChecks': []}]}))
        fixture = self.repo / 'src/test/resources/shared/schema.avsc'
        fixture.parent.mkdir(parents=True)
        fixture.write_text('schema before')
        binary = fixture.with_name('fixture.bin')
        binary.write_bytes(b'before')
        (self.repo / '.gitignore').write_text('*.bin\n')
        self.ready()
        config.write_text('{}')
        scoped.load(self.repo, self.state)
        config.unlink()
        scoped.load(self.repo, self.state)
        for path, value in [(fixture, b'schema after'), (binary, b'after')]:
            before = path.read_bytes()
            path.write_bytes(value)
            with self.assertRaisesRegex(ValueError, 'sources/config changed'):
                scoped.load(self.repo, self.state)
            path.write_bytes(before)

    def test_automatic_shared_input_hashing_without_authored_configuration(self):
        fixture = self.repo / 'src/test/resources/shared/input.bin'
        fixture.parent.mkdir(parents=True)
        fixture.write_bytes(b'before')
        (self.repo / '.gitignore').write_text('*.bin\n')
        self.ready()
        (self.repo / '.makevn/impact.json').write_text('{"tampered":true}')
        scoped.load(self.repo, self.state)  # Generated state is not an authority.
        fixture.write_bytes(b'after')
        with self.assertRaisesRegex(ValueError, 'sources/config changed'):
            scoped.load(self.repo, self.state)

    def test_no_data_and_missing_classes_fail_not_fall_back(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        scoped.finish(self.repo, self.state)
        with self.assertRaisesRegex(ValueError, 'prepare-agent goal.*jacoco.skip=false alone.*selected module target'):
            scoped.load(self.repo, self.state)
        self.compiled.unlink()
        self.ready_without_load()
        with self.assertRaisesRegex(ValueError, 'Missing changed-class'):
            scoped.load(self.repo, self.state)

    def test_no_changed_classes_is_not_applicable_with_or_without_data(self):
        for data in (False, True):
            scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [])
            if data:
                self.ut.write_bytes(b'new UT')
            scoped.finish(self.repo, self.state)
            self.assertEqual(scoped.load(self.repo, self.state)['expected'], [])
            with patch.object(scoped.subprocess, 'run', wraps=subprocess.run) as run, patch('builtins.print') as output:
                scoped.report(self.repo, self.state, 'missing-maven', 'missing-java')
                output.assert_called_once_with('not-applicable')
                self.assertTrue(all(call.args[0][0] == 'git' for call in run.call_args_list))

    def ready_without_load(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        self.ut.write_bytes(b'new')
        scoped.finish(self.repo, self.state)

    def test_not_applicable_still_requires_successful_current_evidence(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client'], [])
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            scoped.load(self.repo, self.state)
        scoped.finish(self.repo, self.state)
        (self.repo / self.source).write_text('class Changed {}')
        with self.assertRaisesRegex(ValueError, 'sources/config changed'):
            scoped.load(self.repo, self.state)

    def test_linked_target_is_rejected_before_data_is_rotated(self):
        target = self.repo / 'client/target'
        moved = self.repo / 'linked-target'
        target.rename(moved)
        target.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'linked coverage target'):
            scoped.prepare(self.repo, self.state, self.repo, ['client'], [self.source])
        self.assertEqual((moved / 'jacoco.exec').read_bytes(), b'old UT')

    def test_changed_comparison_ref_is_rejected(self):
        subprocess.run(['git', '-C', str(self.repo), 'branch', 'comparison'], check=True)
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source], 'comparison...HEAD')
        self.ut.write_bytes(b'new')
        scoped.finish(self.repo, self.state)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'next'], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'branch', '-f', 'comparison', 'HEAD'], check=True)
        with self.assertRaisesRegex(ValueError, 'Comparison base changed'):
            scoped.load(self.repo, self.state)

    def test_comparison_tip_can_advance_without_changing_diff_base(self):
        subprocess.run(['git', '-C', str(self.repo), 'branch', 'comparison'], check=True)
        base_tip = subprocess.check_output([
            'git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
            'commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'base branch work']).decode().strip()
        subprocess.run(['git', '-C', str(self.repo), 'branch', '-f', 'comparison', base_tip], check=True)
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [], 'comparison...HEAD')
        scoped.finish(self.repo, self.state)
        new_tip = subprocess.check_output([
            'git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
            'commit-tree', 'HEAD^{tree}', '-p', 'comparison', '-m', 'unrelated base advancement']).decode().strip()
        subprocess.run(['git', '-C', str(self.repo), 'branch', '-f', 'comparison', new_tip], check=True)
        manifest = scoped.load(self.repo, self.state)
        self.assertNotEqual(manifest['comparison_head'], new_tip)
        scoped.report(self.repo, self.state, 'unused-maven', 'unused-java', 'comparison')
        del manifest['comparison_base']
        (self.state / 'run.json').write_text(json.dumps(manifest))
        scoped.load(self.repo, self.state)
        scoped.report(self.repo, self.state, 'unused-maven', 'unused-java', 'comparison')

    def test_merge_base_change_is_rejected_without_head_change(self):
        subprocess.run(['git', '-C', str(self.repo), 'branch', 'comparison'], check=True)
        feature = subprocess.check_output([
            'git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
            'commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'feature']).decode().strip()
        subprocess.run(['git', '-C', str(self.repo), 'checkout', '--detach', feature], check=True, capture_output=True)
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [], 'comparison...HEAD')
        scoped.finish(self.repo, self.state)
        subprocess.run(['git', '-C', str(self.repo), 'branch', '-f', 'comparison', feature], check=True)
        with self.assertRaisesRegex(ValueError, 'Comparison base changed'):
            scoped.load(self.repo, self.state)

        manifest = json.loads((self.state / 'run.json').read_text())
        del manifest['comparison_base']
        (self.state / 'run.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Comparison base changed'):
            scoped.load(self.repo, self.state)

    def test_report_is_direct_cli_and_reused_by_second_gate(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        original_run = subprocess.run
        def run(command, **kwargs):
            if command[0] == 'git':
                return original_run(command, **kwargs)
            if command[0] == 'mvn':
                self.assertIn('org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy', command)
                self.assertFalse(Path(command[2]).is_relative_to(self.repo))
                self.assertEqual(kwargs['cwd'], self.repo)
                self.assertNotIn('-am', command)
                self.assertNotIn('verify', command)
                (self.state / ('org.jacoco.cli-' + scoped.VERSION + '-nodeps.jar')).touch()
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[3], 'report')
            self.assertNotIn('verify', command)
            (output / 'jacoco.xml').write_text('<report><package name="example"><class name="example/Owner"/></package></report>')
            (output / 'jacoco.csv').write_text('GROUP,PACKAGE,CLASS\nfocused,example,Owner\n')
            (Path(command[command.index('--html') + 1]) / 'index.html').write_text('html')
            return subprocess.CompletedProcess(command, 0, '', '')
        with patch.object(scoped.subprocess, 'run', side_effect=run) as mocked:
            scoped.report(self.repo, self.state, 'mvn', 'java')
            scoped.report(self.repo, self.state, 'mvn', 'java')
            calls = [call for call in mocked.call_args_list if call.args[0][0] == 'java']
            self.assertEqual(len(calls), 1)
            self.assertEqual(len([call for call in mocked.call_args_list if call.args[0][0] == 'mvn']), 1)
            self.assertFalse((output / 'index.html').exists())
            with zipfile.ZipFile(output / 'jacoco-html.zip') as bundle:
                self.assertEqual(bundle.read('index.html'), b'html')

    def test_legacy_html_is_archived_without_invalidating_focused_evidence(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'pkg/index.html'
        html.parent.mkdir()
        html.write_text('http://example.invalid')
        xml = output / 'jacoco.xml'
        xml.write_text('<report/>')
        manifest['report_hashes'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (html, xml)}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        scoped.archive_legacy_html(self.state)
        self.assertFalse(html.exists())
        self.assertEqual(xml.read_text(), '<report/>')
        with zipfile.ZipFile(output / 'jacoco-html.zip') as bundle:
            self.assertEqual(bundle.read('pkg/index.html'), b'http://example.invalid')
        scoped.load(self.repo, self.state)
        scoped.archive_legacy_html(self.state)
        self.assertTrue((output / 'jacoco-html.zip').exists())

    def test_legacy_html_changed_by_user_is_never_removed(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'index.html'
        html.write_text('original')
        manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        html.write_text('user content')
        with self.assertRaisesRegex(ValueError, 'changed'):
            scoped.archive_legacy_html(self.state)
        self.assertEqual(html.read_text(), 'user content')
        self.assertFalse((output / 'jacoco-html.zip').exists())

    def test_interrupted_legacy_cleanup_can_resume(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'index.html'
        html.write_text('legacy')
        manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        unlink = Path.unlink

        def interrupted(path, *args, **kwargs):
            if path == html:
                raise OSError('interrupted cleanup')
            return unlink(path, *args, **kwargs)

        with patch.object(Path, 'unlink', interrupted):
            with self.assertRaisesRegex(OSError, 'interrupted cleanup'):
                scoped.archive_legacy_html(self.state)
        self.assertTrue(html.exists())
        with self.assertRaisesRegex(ValueError, 'cleanup was interrupted'):
            scoped.load(self.repo, self.state)
        scoped.archive_legacy_html(self.state)
        self.assertFalse(html.exists())
        self.assertNotIn('legacy_html_cleanup', json.loads((self.state / 'run.json').read_text()))
        scoped.load(self.repo, self.state)

    def test_interrupted_before_manifest_update_reuses_verified_archive(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'index.html'
        html.write_text('legacy')
        manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        with patch.object(scoped, 'save_manifest', side_effect=OSError('interrupted')):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                scoped.archive_legacy_html(self.state)
        self.assertTrue(html.exists())
        self.assertTrue((output / 'jacoco-html.zip').exists())
        scoped.archive_legacy_html(self.state)
        self.assertFalse(html.exists())
        scoped.load(self.repo, self.state)

    def test_unrelated_existing_archive_is_not_overwritten(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'index.html'
        html.write_text('legacy')
        archive = output / 'jacoco-html.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('user.txt', 'keep')
        manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'does not match'):
            scoped.archive_legacy_html(self.state)
        self.assertTrue(html.exists())
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(bundle.read('user.txt'), b'keep')

    def test_linked_legacy_entries_do_not_touch_external_files(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        external = self.repo / 'external'
        external.mkdir()
        original = external / 'index.html'
        original.write_text('keep')
        (output / 'pkg').symlink_to(external, target_is_directory=True)
        linked = output / 'pkg/index.html'
        manifest['report_hashes'] = {str(linked): hashlib.sha256(original.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Invalid legacy'):
            scoped.archive_legacy_html(self.state)
        self.assertEqual(original.read_text(), 'keep')

    def test_orphaned_legacy_html_without_manifest_is_preserved_and_reported(self):
        output = self.state / 'evidence-orphan/report'
        output.mkdir(parents=True)
        html = output / 'index.html'
        html.write_text('legacy')
        with self.assertRaisesRegex(ValueError, 'without a manifest'):
            scoped.archive_legacy_html(self.state)
        self.assertEqual(html.read_text(), 'legacy')

    def test_linked_manifest_is_not_replaced(self):
        self.state.mkdir(parents=True)
        target = self.repo / 'user-manifest.json'
        target.write_text('{}')
        (self.state / 'run.json').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'linked focused coverage manifest'):
            scoped.archive_legacy_html(self.state)
        self.assertTrue((self.state / 'run.json').is_symlink())
        self.assertEqual(target.read_text(), '{}')

    def test_other_legacy_report_is_not_removed_by_clean(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'index.html'
        html.write_text('current')
        manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        other = self.state / 'evidence-other/report/index.html'
        other.parent.mkdir(parents=True)
        other.write_text('unowned')
        with self.assertRaisesRegex(ValueError, 'not covered by the current manifest'):
            scoped.archive_legacy_html(self.state)
        self.assertEqual(other.read_text(), 'unowned')
        self.assertEqual(html.read_text(), 'current')

    def test_clean_archives_legacy_html_before_invoking_maven(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        output.mkdir()
        html = output / 'index.html'
        html.write_text('http://example.invalid')
        manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
        (self.state / 'run.json').write_text(json.dumps(manifest))
        script = r'''
set -euo pipefail
MAKEVN_LIBEXEC_DIR="$1/libexec/makevn"
source "${MAKEVN_LIBEXEC_DIR}/commands/maven.sh"
makevn_state_dir() { printf '%s/.makevn/state' "$1"; }
makevn_run_maven_goal() { [[ ! -e "$5/index.html" && -f "$5/jacoco-html.zip" ]]; }
makevn_clean_generated_contract_if_needed() { :; }
cmd_clean "$2" -- "$3"
'''
        result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), str(self.repo), str(output)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(html.exists())
        self.assertTrue((output / 'jacoco-html.zip').is_file())

    def test_full_coverage_archives_legacy_html_before_verification(self):
        script = r'''
set -euo pipefail
MAKEVN_LIBEXEC_DIR="$1/libexec/makevn"
source "${MAKEVN_LIBEXEC_DIR}/commands/maven.sh"
CHECK_OUTPUT="$3" VERIFY_RC="$4" LOG_FILE="$5"
makevn_state_dir() { printf '%s/.makevn/state' "$1"; }
makevn_detect_maven_base_path() { printf '%s' "$1"; }
makevn_remove_jacoco_xml_reports() { printf 'remove\n' >> "$LOG_FILE"; }
makevn_require_jacoco_xml_report() { :; }
makevn_print_jacoco_report_hint() { :; }
cmd_verify_ut() { [[ ! -e "$CHECK_OUTPUT/index.html" && -f "$CHECK_OUTPUT/jacoco-html.zip" ]]; printf 'verify\n' >> "$LOG_FILE"; return "$VERIFY_RC"; }
cmd_verify_it() { cmd_verify_ut "$@"; }
makevn_run_maven_goal() { :; }
makevn_clean_generated_contract_if_needed() { :; }
"cmd_verify_${6}_coverage" "$2" "$3" "$4" "$5"
if [[ "$4" == 0 ]]; then cmd_clean "$2"; fi
'''
        for mode in ('ut', 'it'):
            for status in (0, 7):
                with self.subTest(mode=mode, status=status):
                    manifest = self.ready()
                    output = Path(manifest['report'])
                    output.mkdir()
                    html = output / 'index.html'
                    html.write_text('legacy')
                    manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
                    (self.state / 'run.json').write_text(json.dumps(manifest))
                    log = self.repo / 'calls.log'
                    log.unlink(missing_ok=True)
                    result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), str(self.repo), str(output),
                                             str(status), str(log), mode], text=True, capture_output=True)
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(log.read_text(), 'remove\nverify\n')
                    self.assertFalse(html.exists())
                    with zipfile.ZipFile(output / 'jacoco-html.zip') as bundle:
                        self.assertEqual(bundle.read('index.html'), b'legacy')
                    self.assertEqual((self.state / 'run.json').exists(), status != 0)
                    if status:
                        scoped.load(self.repo, self.state)

    def test_full_coverage_does_not_start_if_legacy_report_was_modified(self):
        script = r'''
set -euo pipefail
MAKEVN_LIBEXEC_DIR="$1/libexec/makevn"
source "${MAKEVN_LIBEXEC_DIR}/commands/maven.sh"
CALLS="$3"
makevn_state_dir() { printf '%s/.makevn/state' "$1"; }
makevn_detect_maven_base_path() { printf '%s' "$1"; }
makevn_remove_jacoco_xml_reports() { touch "$CALLS"; }
cmd_verify_ut() { touch "$CALLS"; }
cmd_verify_it() { touch "$CALLS"; }
"cmd_verify_${4}_coverage" "$2"
'''
        for mode in ('ut', 'it'):
            with self.subTest(mode=mode):
                manifest = self.ready()
                output = Path(manifest['report'])
                output.mkdir()
                html = output / 'index.html'
                html.write_text('original')
                manifest['report_hashes'] = {str(html): hashlib.sha256(html.read_bytes()).hexdigest()}
                (self.state / 'run.json').write_text(json.dumps(manifest))
                html.write_text('user content')
                calls = self.repo / 'started'
                result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), str(self.repo),
                                         str(calls), mode], text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Legacy coverage report changed', result.stderr)
                self.assertFalse(calls.exists())
                self.assertEqual(html.read_text(), 'user content')
                self.assertTrue((self.state / 'run.json').exists())


if __name__ == '__main__':
    unittest.main()
