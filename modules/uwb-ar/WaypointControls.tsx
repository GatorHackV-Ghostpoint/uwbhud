import { memo, useEffect, useRef, useState } from 'react';
import { Button, StyleSheet, Text, TextInput, View } from 'react-native';
import { requireNativeModule } from 'expo';

const native = requireNativeModule('UwbAr');
type Room = { revision?: number; canPlace?: boolean; point: { id: string; name?: string; placement?: string; reference: object } | null };
// Memoized: App re-renders ~30x/sec with peer updates, and none of them change these props.
export const WaypointControls = memo(function WaypointControls({ server, device }: { server: string; device: string }) {
  const [allowed, setAllowed] = useState(false);
  const [message, setMessage] = useState('Waiting for waypoint permission…');
  const [hasPoint, setHasPoint] = useState(false);
  const [name, setName] = useState('');
  const nameRef = useRef('');
  const pointID = useRef<string | null>(null);
  const previousName = useRef('Waypoint');
  const [mode, setMode] = useState<'surface' | 'distance'>('surface');
  const [distance, setDistance] = useState('2');
  const [busy, setBusy] = useState(false);
  const mutate = useRef<((action: string) => void) | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    let currentPermission = false;
    let revision = -1;
    let lastPrompt = '';
    const post = async (action: string, payload: object) => {
      const response = await fetch(server + '/waypoint/' + action, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ device, ...payload }), signal: controller.signal,
      });
      const state = await response.json();
      if (!response.ok) throw new Error(state.error || 'Waypoint request failed');
      return state as Room;
    };
    const apply = async (state: Room) => {
      if (controller.signal.aborted || (state.revision ?? 0) < revision) return;
      revision = state.revision ?? revision;
      currentPermission = state.canPlace ?? currentPermission;
      setAllowed(currentPermission);setHasPoint(Boolean(state.point));
      const newName = state.point?.name || 'Waypoint';
      if (state.point && (pointID.current !== state.point.id || nameRef.current === previousName.current)) {
        nameRef.current = newName;setName(newName);
      }
      pointID.current = state.point?.id ?? null;previousName.current = newName;
      const reference = state.point ? { ...state.point.reference, name: newName, placement: state.point.placement || 'surface' } : null;
      await native.updateWaypoint(reference, currentPermission);
    };
    const poll = async () => {
      try {
        const state = await post('phone', {});
        await apply(state);
        const prompt = `${currentPermission}:${Boolean(state.point)}`;
        if (!controller.signal.aborted && !state.point && prompt !== lastPrompt) setMessage(currentPermission ? 'Name the waypoint, choose placement, then tap Place.' : 'Choose a phone in the website waypoint controls.');
        lastPrompt = prompt;
      } catch (error) {
        if (!controller.signal.aborted) {
          currentPermission = false;setAllowed(false);
          void native.updateWaypoint(null, false);
          setMessage(error instanceof Error ? error.message : 'Waypoint connection lost');
        }
      } finally { if (!controller.signal.aborted) timer = setTimeout(poll, 1000); }
    };
    mutate.current = action => {
      if (!currentPermission) return;
      setBusy(true);
      void native.cancelWaypoint();
      void post(action, { name: nameRef.current }).then(async state => {
        await apply(state);
        if (!controller.signal.aborted) setMessage(action === 'clear' ? 'Waypoint cleared for everyone.' : 'Waypoint name saved.');
      }).catch(error => { if (!controller.signal.aborted) setMessage(error.message); })
        .finally(() => { if (!controller.signal.aborted) setBusy(false); });
    };
    const tap = native.addListener('onWaypointTap', (event: { reference: object; placement?: string }) => {
      if (!currentPermission) return;
      setBusy(true);
      void post('set', { reference: event.reference, name: nameRef.current, placement: event.placement || 'surface' }).then(async state => {
        await apply(state);
        if (!controller.signal.aborted) setMessage('Waypoint shared with the team.');
      }).catch(error => { if (!controller.signal.aborted) setMessage(error.message); })
        .finally(() => { if (!controller.signal.aborted) setBusy(false); });
    });
    const status = native.addListener('onWaypointStatus', (event: { message: string }) => {
      if (!controller.signal.aborted) setMessage(event.message);
    });
    void poll();
    return () => {controller.abort();clearTimeout(timer);mutate.current = null;tap.remove();status.remove();void native.updateWaypoint(null, false);};
  }, [server, device]);
  return <View style={styles.panel}>
    <Text style={styles.title}>◆ TEAM WAYPOINT</Text>
    <Text style={styles.text}>{message}</Text>
    {allowed && <>
      <TextInput style={styles.input} placeholder="Waypoint name (optional)" placeholderTextColor="#bba577" value={name} maxLength={40}
        onChangeText={value => { nameRef.current = value;setName(value); }} accessibilityLabel="Waypoint name" />
      <View style={styles.row}>
        <Button color={mode === 'surface' ? '#ffbd42' : '#aaa'} title="Surface" onPress={() => {setMode('surface');void native.cancelWaypoint();}} />
        <Button color={mode === 'distance' ? '#ffbd42' : '#aaa'} title="Distance" onPress={() => {setMode('distance');void native.cancelWaypoint();}} />
        {hasPoint && <Button title="Save name" disabled={busy} onPress={() => mutate.current?.('rename')} />}
      </View>
      {mode === 'distance' && <>
        <Text style={styles.text}>Estimated placement: choose 0.2–15 metres, then tap a direction.</Text>
        <TextInput style={styles.input} value={distance} onChangeText={setDistance} keyboardType="decimal-pad" maxLength={5} accessibilityLabel="Waypoint distance in metres" />
      </>}
      <View style={styles.row}>
        <Button color="#ffbd42" disabled={busy} title={hasPoint ? 'Replace waypoint' : 'Place waypoint'} onPress={() => {
          const metres = Number(distance.replace(',', '.'));
          if (mode === 'distance' && (!Number.isFinite(metres) || metres < 0.2 || metres > 15)) {setMessage('Enter a distance between 0.2 and 15 metres.');return;}
          void native.armWaypoint(mode === 'distance' ? metres : null);
          setMessage(mode === 'distance' ? 'Tap a direction for the estimated distance placement.' : 'Tap a floor, wall or object. Scan slowly if needed.');
        }} />
        {hasPoint && <Button color="#ffbd42" disabled={busy} title="Clear waypoint" onPress={() => mutate.current?.('clear')} />}
      </View>
    </>}
  </View>;
});
const styles = StyleSheet.create({
  panel: { borderWidth: 1, borderColor: '#ffbd42', borderRadius: 3, padding: 5, marginTop: 4, backgroundColor: '#211b10' },
  title: { color: '#ffbd42', fontWeight: 'bold', fontSize: 12, textAlign: 'center' },
  text: { color: '#ffe4aa', fontSize: 11, textAlign: 'center' },
  input: { color: '#ffe4aa', borderBottomWidth: 1, borderColor: '#866729', padding: 5, fontSize: 12 },
  row: { flexDirection: 'row', justifyContent: 'space-around', alignItems: 'center' },
});
