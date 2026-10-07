"""Independent audit of real Quest ContentResolver/file access reports."""
import copy
import json
import re
import sys
from pathlib import Path

CASES = {
    'file_present': ('readable', '', True),
    'file_missing': ('error', 'LOCAL_DOCUMENT_MISSING', False),
    'content_present': ('readable', '', False),
    'content_missing': ('error', 'LOCAL_DOCUMENT_MISSING', False),
    'content_denied': ('error', 'LOCAL_DOCUMENT_PERMISSION_LOST', False),
    'cancel': ('error', 'LOCAL_DOCUMENT_CANCELLED', False),
    'timeout': ('error', 'LOCAL_DOCUMENT_TIMEOUT', False),
}


def verify(data):
    result, build, reports, receipts, log = data
    assert result['state'] == 'collected_scoped_local_access_trace'
    assert re.fullmatch(r'[0-9a-f]{64}', result['apk_sha256'])
    assert result['apk_sha256'] == result['installed_sha256'] == build['apk_sha256']
    assert result['activity_launched'] is False
    assert not re.search(r'FATAL EXCEPTION:|SCRIPT ERROR:|SHADER ERROR:', log)
    processes, ids, requests = set(), set(), set()
    for case, (state, error, persisted) in CASES.items():
        receipt, report = receipts[case], reports[case]
        assert receipt['state'] == 'accepted'
        assert receipt['action'] == 'org.vrpassthroughplayer.quest.DEBUG_LOCAL_ACCESS'
        assert re.fullmatch(r'access_[0-9a-f]{32}', receipt['request'])
        assert receipt['request'] not in requests
        requests.add(receipt['request'])
        assert report['case'] == case
        assert report['request_id'] == receipt['id'] and type(receipt['id']) is int and receipt['id'] > 0
        identity = (receipt['diagnostic_process'], receipt['id'])
        assert identity not in ids
        ids.add(identity)
        assert report['diagnostic_process'] == receipt['diagnostic_process']
        assert re.fullmatch(r'[0-9a-f-]{36}', receipt['diagnostic_process'])
        processes.add(receipt['diagnostic_process'])
        assert report['state'] == state and report['error'] == error
        assert report['persisted_permission'] is persisted
        path = 'slow' if case in ('cancel', 'timeout') else case.split('_')[1]
        if case.startswith('content_') or case in ('cancel', 'timeout'):
            assert report['uri'] == f'content://org.vrpassthroughplayer.quest.accessfixture/{path}'
        else:
            name = 'local-access-file.bin' if case == 'file_present' else 'missing-access-file.bin'
            assert re.fullmatch(r'file:///data/(user/0|data)/org\.vrpassthroughplayer\.quest/cache/' + re.escape(name), report['uri'])
        elapsed = report['elapsed_ms']
        assert type(elapsed) is int and elapsed >= 0
        if case == 'cancel':
            assert 150 <= elapsed < 2000
        elif case == 'timeout':
            assert 9500 <= elapsed < 14000
        else:
            assert elapsed < 5000
    assert len(processes) == 1


def main():
    directory = Path(sys.argv[1])
    read = lambda name: json.loads((directory/name).read_text(encoding='utf-8-sig'))
    data = [read('result.json'), read('build_manifest.json'),
            {c: read(c+'-report.json') for c in CASES},
            {c: read(c+'-receipt.json') for c in CASES},
            (directory/'logcat.txt').read_text(encoding='utf-8-sig')]
    verify(data)
    mutations = []
    def reject(label, change):
        bad = copy.deepcopy(data)
        change(bad)
        try:
            verify(bad)
        except (AssertionError, KeyError, TypeError):
            mutations.append(label)
        else:
            raise AssertionError('Audit accepted polluted evidence: '+label)
    reject('different_apk', lambda d: d[0].update(installed_sha256='0'*64))
    reject('activity_scope', lambda d: d[0].update(activity_launched=True))
    reject('stale_process', lambda d: d[2]['content_present'].update(diagnostic_process='00000000-0000-0000-0000-000000000000'))
    reject('stale_id', lambda d: d[2]['content_present'].update(request_id=999999))
    reject('wrong_uri', lambda d: d[2]['content_present'].update(uri='content://other/present'))
    reject('permission_category', lambda d: d[2]['content_denied'].update(error='LOCAL_DOCUMENT_MISSING'))
    reject('missing_category', lambda d: d[2]['content_missing'].update(error='LOCAL_DOCUMENT_PERMISSION_LOST'))
    reject('invented_grant', lambda d: d[2]['content_present'].update(persisted_permission=True))
    reject('cancel_waits_for_timeout', lambda d: d[2]['cancel'].update(elapsed_ms=10000))
    reject('timeout_is_immediate', lambda d: d[2]['timeout'].update(elapsed_ms=200))
    reject('native_crash', lambda d: d.__setitem__(4, d[4]+'\nFATAL EXCEPTION: main'))
    output = {'state':'passed_scoped_local_access', 'apk_sha256':data[0]['apk_sha256'],
              'cases':len(CASES), 'polluted_evidence_rejected':mutations,
              'elapsed_ms':{c:data[2][c]['elapsed_ms'] for c in CASES},
              'scope':data[0]['scope'], 'external_saf_grants_verified':False,
              'android_catalog_persistence_verified':False, 'mpv_decode_verified':False,
              'xr_verified':False}
    (directory/'local-access-verified.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(output,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    main()
