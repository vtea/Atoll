import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = json.loads(subprocess.check_output([
            'ruby', '-rjson', '-ryaml', '-e',
            'puts JSON.generate(YAML.load_file(ARGV[0]))',
            str(ROOT / '.github/workflows/release.yml'),
        ]))
        cls.steps = cls.workflow['jobs']['release']['steps']

    def step(self, name):
        return next(s for s in self.steps if s.get('name') == name)

    def test_step_environment_is_a_mapping(self):
        for step in self.steps:
            if 'env' in step:
                self.assertIsInstance(step['env'], dict, step['name'])

    def test_shell_steps_parse(self):
        for step in self.steps:
            if 'run' in step:
                script = re.sub(r'\$\{\{.*?\}\}', 'EXPRESSION', step['run'])
                result = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, (step['name'], result.stderr))

    def test_tag_matches_package_version(self):
        script = self.step('Compute Version')['run'].replace('${{ steps.channel.outputs.channel }}', 'copy')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            subprocess.run(['git', '-C', directory, '-c', 'user.name=Test', '-c',
                            'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
            (path / 'VERSION').write_text('0.0.2\n')
            (path / 'Updates').mkdir()
            (path / 'Updates/appcast.xml').write_text('<sparkle:version>1637</sparkle:version>')
            env = dict(os.environ, GITHUB_REF_TYPE='tag', GITHUB_REF_NAME='v0.0.2',
                       APP_NAME='Atoll', GITHUB_OUTPUT=str(path / 'output'))
            result = subprocess.run(['bash', '-eo', 'pipefail', '-c', script], cwd=path, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = (path / 'output').read_text()
            self.assertIn('tag=v0.0.2\n', output)
            self.assertIn('version=0.0.2\n', output)
            self.assertIn('build_number=1638\n', output)
            env['GITHUB_REF_NAME'] = 'v0.0.1'
            result = subprocess.run(['bash', '-eo', 'pipefail', '-c', script], cwd=path, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_incomplete_credentials_cannot_downgrade_signing(self):
        script = self.step('Detect code signing credentials')['run'].replace('${{ steps.channel.outputs.channel }}', 'copy')
        names = ['CERTIFICATE_P12', 'CERTIFICATE_PASSWORD', 'KEYCHAIN_PASSWORD',
                 'API_KEY_P8', 'API_KEY_ID', 'API_KEY_ISSUER']
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            env = dict(os.environ, GITHUB_OUTPUT=str(output))
            env.update({name: '' for name in names})
            for supplied, success, setting in [(0, True, 'false'), (1, False, None), (6, True, 'true')]:
                env.update({name: 'fixture' if index < supplied else '' for index, name in enumerate(names)})
                output.write_text('')
                result = subprocess.run(['bash', '-eo', 'pipefail', '-c', script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout)
                if setting:
                    self.assertIn(f'enabled={setting}\n', output.read_text())
                else:
                    self.assertNotIn('enabled=false', output.read_text())

    def test_existing_release_is_not_deleted(self):
        script = self.step('Create GitHub Release')['run']
        self.assertNotIn('gh release delete', script)
        self.assertNotIn('git tag -d', script)
        self.assertIn('git rev-list -n 1 "$TAG"', script)


if __name__ == '__main__':
    unittest.main()
