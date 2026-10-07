"""Independently verify production Android asynchronous document selection."""
import copy
import json
from pathlib import Path
import re
import sys

CASES=['unicode','long','blank','no_column','metadata_denied','missing','permission_denied','cancel','timeout','replace_late','close_late','external']
PATHS=dict(unicode='name_unicode',long='name_long',blank='name_blank',no_column='name_no_column',metadata_denied='name_denied',missing='missing',permission_denied='denied',cancel='name_slow',timeout='name_slow',replace_late='name_late',close_late='name_late')


def verify(data):
    result,build,reports,receipts,log,grant,cleanup=data
    assert result['state']=='collected_scoped_selection_trace'
    assert result['apk_sha256']==result['installed_sha256']==build['apk_sha256']
    assert re.fullmatch(r'[0-9a-f]{64}',result['apk_sha256']) and result['activity_launched'] is False
    assert not re.search(r'FATAL EXCEPTION:|SCRIPT ERROR:|SHADER ERROR:',log)
    assert grant['state']=='applied' and grant['operation']=='offer_persistable'
    assert cleanup['state']=='applied' and cleanup['operation']=='revoke'
    assert grant['client_uid']!=grant['provider_uid']
    processes=set()
    identities=set()
    requests=set()
    for case in CASES:
        report,receipt=reports[case],receipts[case]
        assert receipt['action']=='org.vrpassthroughplayer.quest.DEBUG_LOCAL_SELECTION'
        assert receipt['state']=='accepted' and receipt['id']>0
        assert re.fullmatch(r'selection_[0-9a-f]{32}',receipt['request']) and receipt['request'] not in requests
        requests.add(receipt['request'])
        assert report['case']==case and report['request_id']==receipt['id']
        assert report['diagnostic_process']==receipt['diagnostic_process']
        identity=(receipt['diagnostic_process'],receipt['id'])
        assert identity not in identities
        identities.add(identity)
        processes.add(receipt['diagnostic_process'])
        assert report['accepted'] is True and report['all_events_main'] is True
        assert 0<=report['start_return_ms']<250 and 0<report['main_max_gap_ms']<500
        assert report['main_heartbeat_count']>=report['elapsed_ms']//100
        expected_uri='content://org.vrpassthroughplayer.urifixture.documents/document/clip' if case=='external' else 'content://org.vrpassthroughplayer.quest.accessfixture/'+PATHS[case]
        assert report['uri']==expected_uri
        events=report['events']
        assert events[0]['state']=='checking' and events[0]['selection_id']==1
        if case=='close_late':
            assert len(events)==1 and report['elapsed_ms']>=1700
            continue
        if case=='replace_late':
            assert [e['state'] for e in events]==['checking','checking','selected']
            assert [e['selection_id'] for e in events]==[1,2,2]
            assert events[-1]['uri']=='content://org.vrpassthroughplayer.quest.accessfixture/name_unicode'
            assert 1000<=events[-1]['elapsed_ms']<1800
        else:
            assert len(events)==2 and events[-1]['selection_id']==1
        terminal=events[-1]
        if case in ('missing','permission_denied','timeout'):
            assert terminal['state']=='error'
            assert terminal['error']=={'missing':'LOCAL_DOCUMENT_MISSING','permission_denied':'LOCAL_DOCUMENT_PERMISSION_LOST','timeout':'LOCAL_DOCUMENT_TIMEOUT'}[case]
            if case=='timeout':
                assert 9500<=terminal['elapsed_ms']<11000
        elif case=='cancel':
            assert terminal['state']=='cancelled' and 150<=terminal['elapsed_ms']<700
        else:
            assert terminal['state']=='selected' and terminal['persisted_permission'] is (case=='external')
            name=terminal['display_name']
            assert name==({'unicode':'中文字幕 😀 A B C','long':'界'*255+'😀','external':'测试视频 😀.mp4','replace_late':'中文字幕 😀 A B C'}.get(case,'Local video'))
            assert '\n' not in name and '\r' not in name and '\t' not in name
            assert len(name)<=256 and not any(0xd800<=ord(c)<=0xdfff for c in name)
            if case!='replace_late':
                assert terminal['uri']==expected_uri and terminal['elapsed_ms']<400
    assert len(processes)==1


def main():
    directory=Path(sys.argv[1])
    read=lambda n:json.loads((directory/n).read_text(encoding='utf-8-sig'))
    data=[read('result.json'),read('build_manifest.json'),{c:read(c+'-report.json') for c in CASES},
          {c:read(c+'-receipt.json') for c in CASES},(directory/'logcat.txt').read_text(encoding='utf-8-sig'),
          read('provider-offer_persistable.json'),read('provider-revoke.json')]
    verify(data)
    rejected=[]
    def reject(name,mutate):
        bad=copy.deepcopy(data)
        mutate(bad)
        try:
            verify(bad)
        except (AssertionError,KeyError,TypeError): rejected.append(name)
        else: raise AssertionError('Polluted selection evidence accepted: '+name)
    reject('wrong_apk',lambda d:d[0].update(installed_sha256='0'*64))
    reject('stale_id',lambda d:d[2]['unicode'].update(request_id=9999))
    reject('stale_process',lambda d:d[2]['unicode'].update(diagnostic_process='stale'))
    reject('blocking_start',lambda d:d[2]['timeout'].update(start_return_ms=10000))
    reject('main_blocked',lambda d:d[2]['timeout'].update(main_max_gap_ms=10000))
    reject('missing_heartbeat',lambda d:d[2]['timeout'].update(main_heartbeat_count=0))
    reject('event_off_main',lambda d:d[2]['unicode'].update(all_events_main=False))
    reject('invalid_unicode',lambda d:d[2]['long']['events'][-1].update(display_name='界'*255+'\ud83d'))
    reject('metadata_denial_stops_playback',lambda d:d[2]['metadata_denied']['events'][-1].update(state='error'))
    reject('timeout_too_early',lambda d:d[2]['timeout']['events'][-1].update(elapsed_ms=10))
    reject('cancel_waits_for_provider',lambda d:d[2]['cancel']['events'][-1].update(elapsed_ms=1200))
    reject('old_request_selected',lambda d:d[2]['replace_late']['events'][-1].update(selection_id=1))
    reject('late_selection_after_close',lambda d:d[2]['close_late']['events'].append({'state':'selected','selection_id':1}))
    reject('invented_external_grant',lambda d:d[2]['external']['events'][-1].update(persisted_permission=False))
    output=dict(state='passed_scoped_async_selection',apk_sha256=data[0]['apk_sha256'],cases=len(CASES),
                polluted_evidence_rejected=rejected,main_max_gap_ms=max(r['main_max_gap_ms'] for r in data[2].values()),
                maximum_start_return_ms=max(r['start_return_ms'] for r in data[2].values()),
                timeout_ms=data[2]['timeout']['events'][-1]['elapsed_ms'],cancel_ms=data[2]['cancel']['events'][-1]['elapsed_ms'],
                scope=data[0]['scope'],system_picker_ui_verified=False,Godot_playback_verified=False,XR_verified=False)
    (directory/'selection-verified.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(output,ensure_ascii=False,indent=2))


if __name__=='__main__': main()
