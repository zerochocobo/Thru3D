"""Audit two actual Android UIDs, grants and source-frame MPV FD decode."""
import os
from pathlib import Path
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

from mpv_source_probe import verify as verify_source

ROOT = Path(__file__).resolve().parents[1]
URI = 'content://org.vrpassthroughplayer.urifixture.documents/document/clip'
CHECKS = {
    'no_grant': ('external_check', 'error', 'LOCAL_DOCUMENT_PERMISSION_LOST', False, False),
    'temporary_check': ('external_check', 'readable', '', False, False),
    'cannot_persist_temporary': ('external_take', 'readable', '', False, False),
    'offered_check': ('external_check', 'readable', '', False, False),
    'take_persistable': ('external_take', 'readable', '', True, True),
    'player_restart': ('external_check', 'readable', '', True, False),
    'provider_restart': ('external_check', 'readable', '', True, False),
    'missing_document': ('external_check', 'error', 'LOCAL_DOCUMENT_MISSING', True, False),
    'restored_document': ('external_check', 'readable', '', True, False),
    'released_and_revoked': ('external_check', 'error', 'LOCAL_DOCUMENT_PERMISSION_LOST', False, False),
    'retake': ('external_take', 'readable', '', True, True),
    'revoked_persisted': ('external_check', 'error', 'LOCAL_DOCUMENT_PERMISSION_LOST', False, False),
    'reselected': ('external_take', 'readable', '', True, True),
}
OPERATIONS = {'restore':'restore','reset_grants':'revoke','temporary':'grant','revoke_temporary':'revoke',
              'offer_persistable':'offer_persistable','remove':'remove','restore_again':'restore',
              'revoke_released':'revoke','offer_again':'offer_persistable','revoke_persisted':'revoke',
              'offer_reselected':'offer_persistable','cleanup_grants':'revoke'}


def verify(data):
    result, build, providers, reports, receipts, package_texts, log = data
    assert result['state'] == 'collected_scoped_external_uri_trace'
    assert result['apk_sha256'] == build['apk_sha256'] and re.fullmatch(r'[0-9a-f]{64}',result['apk_sha256'])
    assert re.fullmatch(r'[0-9a-f]{64}',result['provider_apk_sha256']) and result['activity_launched'] is False
    assert not re.search(r'FATAL EXCEPTION:|SCRIPT ERROR:|SHADER ERROR:',log)
    client_uid = int(re.search(r'package:org\.vrpassthroughplayer\.quest\s+uid:(\d+)',package_texts[0]).group(1))
    provider_uid = int(re.search(r'package:org\.vrpassthroughplayer\.urifixture\s+uid:(\d+)',package_texts[1]).group(1))
    assert client_uid != provider_uid and client_uid >= 10000 and provider_uid >= 10000
    fixture = json.loads((ROOT/'tests/fixtures/mp03_frame_identity.json').read_text())
    assert hashlib.sha256((ROOT/fixture['file']).read_bytes()).hexdigest() == fixture['sha256']
    requests = set()
    for label, operation in OPERATIONS.items():
        report = providers[label]
        assert report['state'] == 'applied' and report['operation'] == operation and report['uri'] == URI
        assert report['provider_uid'] == provider_uid and report['client_uid'] == client_uid
        assert re.fullmatch(r'provider_[0-9a-f]{32}',report['request']) and report['request'] not in requests
        requests.add(report['request'])
        assert re.fullmatch(r'[0-9a-f-]{36}',report['provider_process'])
        assert report['clip_exists'] is (label != 'remove')
        if report['clip_exists']:
            assert report['clip_sha256'] == fixture['sha256']
    assert providers['restore']['provider_process'] != providers['remove']['provider_process']
    identities = set()
    for label, report in reports.items():
        receipt = receipts[label]
        assert receipt['state'] == 'accepted' and receipt['id'] > 0
        assert re.fullmatch(r'player_[0-9a-f]{32}',receipt['request']) and receipt['request'] not in requests
        requests.add(receipt['request'])
        expected_action = 'DEBUG_MPV_URI' if label == 'native_decode' else 'DEBUG_LOCAL_ACCESS'
        assert receipt['action'] == 'org.vrpassthroughplayer.quest.'+expected_action
        assert report['request_id'] == receipt['id'] and report['diagnostic_process'] == receipt['diagnostic_process']
        assert re.fullmatch(r'[0-9a-f-]{36}',receipt['diagnostic_process'])
        identity = (receipt['action'], receipt['diagnostic_process'], receipt['id'])
        assert identity not in identities
        identities.add(identity)
        assert report['uri'] == URI and report['client_uid'] == client_uid
    assert reports['no_grant']['diagnostic_process'] != reports['player_restart']['diagnostic_process']
    for label in CHECKS:
        expected_process = reports['no_grant']['diagnostic_process'] if label in ('no_grant','temporary_check','cannot_persist_temporary','offered_check','take_persistable') else reports['player_restart']['diagnostic_process']
        assert reports[label]['diagnostic_process'] == expected_process
        case, state, error, snapshot, taken = CHECKS[label]
        report = reports[label]
        assert report['case'] == case and report['state'] == state and report['error'] == error
        assert report['persisted_permission_snapshot'] is snapshot and report['grant_taken'] is taken
        assert report['grant_released'] is False
        assert report['persisted_permission'] is (snapshot and state == 'readable')
        assert 0 <= report['elapsed_ms'] < 5000
    released = reports['release_persistable']
    assert released['case'] == 'external_release' and released['grant_released'] is True
    assert released['persisted_permission_snapshot'] is False and released['persisted_permission'] is False
    # Releasing persistence does not itself certify removal of every temporary
    # grant. The explicit provider revoke is audited separately above.
    assert (released['state'],released['error']) in [('readable',''),('error','LOCAL_DOCUMENT_PERMISSION_LOST')]
    native = reports['native_decode']
    assert native['diagnostic_process'] == reports['player_restart']['diagnostic_process']
    assert native['descriptor_bytes'] == (ROOT/fixture['file']).stat().st_size


def main():
    directory = Path(sys.argv[1])
    read = lambda name: json.loads((directory/name).read_text(encoding='utf-8-sig'))
    labels = list(CHECKS)+['release_persistable','native_decode']
    data = [read('result.json'),read('build_manifest.json'),
            {label:read(label+'-provider.json') for label in OPERATIONS},
            {label:read(label+'-report.json') for label in labels},
            {label:read(label+'-receipt.json') for label in labels},
            [(directory/name).read_text(encoding='utf-8-sig') for name in ('player-uid.txt','provider-uid.txt')],
            (directory/'player-logcat.txt').read_text(encoding='utf-8-sig')]
    verify(data)
    native = verify_source(data[3]['native_decode'], os.environ.get('THRU3D_FFMPEG', 'ffmpeg'))
    mutations = []
    def reject(label, change):
        bad = copy.deepcopy(data)
        change(bad)
        try:
            verify(bad)
        except (AssertionError,KeyError,TypeError):
            mutations.append(label)
        else:
            raise AssertionError('Accepted polluted evidence: '+label)
    reject('different_build',lambda d:d[0].update(apk_sha256='0'*64))
    reject('same_uid',lambda d:d[2]['restore'].update(provider_uid=d[2]['restore']['client_uid']))
    reject('wrong_source_bytes',lambda d:d[2]['restore'].update(clip_sha256='0'*64))
    reject('stale_provider',lambda d:d[2]['remove'].update(provider_process=d[2]['restore']['provider_process']))
    reject('stale_player',lambda d:d[3]['player_restart'].update(diagnostic_process=d[3]['no_grant']['diagnostic_process']))
    reject('invented_persisted_grant',lambda d:d[3]['temporary_check'].update(persisted_permission=True))
    reject('temporary_grant_taken',lambda d:d[3]['cannot_persist_temporary'].update(grant_taken=True))
    reject('lost_grant_after_restart',lambda d:d[3]['player_restart'].update(persisted_permission_snapshot=False))
    reject('deletion_misclassified_as_revocation',lambda d:d[3]['missing_document'].update(error='LOCAL_DOCUMENT_PERMISSION_LOST'))
    reject('revocation_misclassified_as_deletion',lambda d:d[3]['revoked_persisted'].update(error='LOCAL_DOCUMENT_MISSING'))
    reject('wrong_uri',lambda d:d[3]['reselected'].update(uri='content://other/document/clip'))
    reject('stale_request',lambda d:d[3]['reselected'].update(request_id=999999))
    reject('persistent_release_ignored',lambda d:d[3]['release_persistable'].update(persisted_permission_snapshot=True))
    reject('wrong_fd_size',lambda d:d[3]['native_decode'].update(descriptor_bytes=4))
    reject('cleanup_not_revoke',lambda d:d[2]['cleanup_grants'].update(operation='grant'))
    output = dict(state='passed_scoped_cross_UID_document_and_native_MPV_FD',apk_sha256=data[0]['apk_sha256'],
                  provider_apk_sha256=data[0]['provider_apk_sha256'],client_uid=data[2]['restore']['client_uid'],
                  provider_uid=data[2]['restore']['provider_uid'],document_access_observations=14,
                  provider_operations=len(OPERATIONS),polluted_evidence_rejected=mutations,
                  native_source_identity=native,scope=data[0]['scope'],system_picker_ui_verified=False,
                  device_reboot_persistence_verified=False,android_catalog_verified=False,actual_Godot_resume_verified=False,
                  rvm_xr_verified=False,audio_verified=False)
    (directory/'external-uri-verified.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in output.items() if k != 'native_source_identity'},ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in native.items() if k != 'comparisons'}))


if __name__ == '__main__':
    main()
