import { useCallback, useEffect, useRef, useState } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import { requireNativeModule } from 'expo';
import { WaypointControls } from './WaypointControls';

type BroadcastStatus = { state: string; message?: string };
const native = requireNativeModule('UwbAr');
// A permanent server domain can replace this temporary demo origin in one place.
const SERVER = 'https://parents-costumes-eco-threshold.trycloudflare.com';

export function BroadcastControls() {
  const [status, setStatus] = useState<BroadcastStatus>({ state: 'stopped' });
  const [slot, setSlot] = useState('Automatic phone slot');
  const [pending, setPending] = useState(false);
  const [device, setDevice] = useState<string | null>(null);
  const lease = useRef<string | null>(null);
  const mounted = useRef(true);
  const request = useRef<AbortController | null>(null);
  const active = !['stopped', 'error'].includes(status.state);
  const release = useCallback(() => {
    const token = lease.current;
    lease.current = null;
    if (mounted.current) setDevice(null);
    if (token) void fetch(SERVER + '/broadcast/release', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ lease: token }),
    }).catch(() => {});
  }, []);
  useEffect(() => {
    mounted.current = true;
    const subscription = native.addListener('onBroadcastStatus', (event: BroadcastStatus) => {
      if (!mounted.current) return;
      setStatus(event);
      if (['stopped', 'error'].includes(event.state)) release();
    });
    void fetch(SERVER + '/broadcast/slots').then(response => {
      if (!response.ok) throw new Error();
      if (mounted.current) setSlot('Connected to server · automatic phone slot');
    }).catch(() => { if (mounted.current) setSlot('Server unavailable · tap Start to retry'); });
    return () => {
      mounted.current = false;request.current?.abort();subscription.remove();
      void native.stopBroadcast();release();
    };
  }, [release]);
  async function toggle() {
    setPending(true);
    try {
      if (active) { await native.stopBroadcast();release(); }
      else {
        setStatus({ state: 'assigning' });
        const controller = new AbortController();request.current = controller;
        const deadline = setTimeout(() => controller.abort(), 15000);
        let response: Response;
        try { response = await fetch(SERVER + '/broadcast/claim', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: controller.signal }); }
        finally { clearTimeout(deadline);request.current = null; }
        const assignment = await response.json();
        if (!response.ok) throw new Error(assignment.error || 'Could not assign a phone slot.');
        lease.current = assignment.lease;
        if (mounted.current) setDevice(assignment.lease);
        if (!mounted.current) { release();return; }
        if (!['/media/hud/whip', '/media/hud2/whip', '/media/hud3/whip', '/media/hud4/whip'].includes(assignment.path)) {
          throw new Error('Server returned an invalid phone slot.');
        }
        setSlot('Phone ' + (['hud', 'hud2', 'hud3', 'hud4'].indexOf(assignment.stream) + 1));
        await native.startBroadcast(SERVER + assignment.path, '');
      }
    } catch (error) {
      release();
      if (mounted.current) setStatus({ state: 'error', message: error instanceof Error ? error.message : 'Broadcast failed' });
    } finally { if (mounted.current) setPending(false); }
  }
  return (
    <View style={styles.panel}>
      <Text style={styles.status}>{slot}</Text>
      <Button title={active ? 'Stop Broadcast' : 'Start Broadcast'} onPress={toggle} disabled={pending} />
      <Text style={styles.status} accessibilityLiveRegion="polite">Broadcast: {status.state}{status.message ? ` · ${status.message}` : ''}</Text>
      {device && <WaypointControls server={SERVER} device={device} />}
    </View>
  );
}
const styles = StyleSheet.create({
  panel: { position: 'absolute', left: 12, right: 12, bottom: 8, backgroundColor: 'rgba(0,0,0,0.65)', borderRadius: 8, padding: 6 },
  status: { color: 'white', fontSize: 11, textAlign: 'center' },
});
