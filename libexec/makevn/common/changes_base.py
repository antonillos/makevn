"""Offline comparison-base resolution for changed-code commands."""
import subprocess
import sys


def git(repo, *args):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def resolve(repo, reference):
    if not reference or reference.startswith('-') or '...' in reference or '..' in reference:
        raise ValueError('Expected a single commit reference for --base, not a revision range')
    commit = git(repo, 'rev-parse', '--verify', '--end-of-options', reference + '^{commit}')
    if not commit:
        raise ValueError('Base reference is unavailable or is not a commit: ' + reference +
                         '. Supply --base <local-ref>; no fetch was performed.')
    bases = git(repo, 'merge-base', '--all', commit, 'HEAD').splitlines()
    if len(bases) != 1:
        raise ValueError('Base reference requires exactly one available merge base: ' + reference +
                         '. Check unrelated/shallow history or multiple merge bases; supply --base <commit>.')
    return commit, bases[0]


def detect(repo):
    branch = git(repo, 'rev-parse', '--abbrev-ref', 'HEAD')
    if branch in {'develop', 'main', 'master'}:
        return 'HEAD'
    candidates = ['origin/main', 'main', 'origin/develop', 'develop', 'origin/master', 'master']
    candidates += git(repo, 'for-each-ref', '--format=%(refname:short)',
                      'refs/remotes/origin/release', 'refs/heads/release').splitlines()
    history = set(git(repo, 'rev-list', '--first-parent', 'HEAD').splitlines())
    ranked = []
    for candidate in candidates:
        if candidate == branch:
            continue
        if not git(repo, 'rev-parse', '--verify', candidate):
            continue
        if not git(repo, 'merge-base', '--all', candidate, 'HEAD'):
            continue
        commit, base = resolve(repo, candidate)
        distance = git(repo, 'rev-list', '--first-parent', '--count', base + '..HEAD')
        if distance.isdigit():
            ranked.append(((int(distance), commit not in history), candidate, base))
    if not ranked:
        return 'HEAD'
    best = min(item[0] for item in ranked)
    tied = [item for item in ranked if item[0] == best]
    # Equal merge bases preserve the same first-parent replay and local inputs,
    # even when the candidate tips have advanced independently.
    if len({item[2] for item in tied}) > 1:
        names = ', '.join(item[1] for item in tied)
        raise ValueError('Ambiguous changed-code base: ' + names +
                         '. Select the intended destination explicitly, for example: '
                         'makevn verify-changes-preview --base ' + tied[0][1])
    return tied[0][1] + '...HEAD'


def main(args):
    repo, *references = args
    if references:
        reference = references[0]
        resolve(repo, reference)
        print(reference + '...HEAD')
    else:
        print(detect(repo))


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except ValueError as error:
        print('Error: ' + str(error), file=sys.stderr)
        sys.exit(2)
