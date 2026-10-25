import { useEffect, useState } from 'react';
import { Button, StyleSheet, Text, TextInput, View } from 'react-native';
import { requireNativeModule } from 'expo';

type BroadcastStatus = { state: string; message?: string };
const native = requireNativeModule('UwbAr');

export function BroadcastControls() {
  const [url, setUrl] = useState('');
  const [status, setStatus] = useState<BroadcastStatus>({ state: 'stopped' });
  const [pending, setPending] = useState(false);
  const active = !['stopped', 'error'].includes(status.state);
  useEffect(() => {
    const subscription = native.addListener('onBroadcastStatus', setStatus);
    return () => { subscription.remove(); void native.stopBroadcast(); };
  }, []);
  async function toggle() {
    setPending(true);
    try {
      if (active) await native.stopBroadcast();
      else await native.startBroadcast(url.trim(), '');
    } catch (error) {
      setStatus({ state: 'error', message: error instanceof Error ? error.message : 'Broadcast failed' });
    } finally { setPending(false); }
  }
  return (
    <View style={styles.panel}>
      {!active && <>
        <TextInput style={styles.input} value={url} onChangeText={setUrl} placeholder="HTTPS HUD WHIP URL"
          placeholderTextColor="#bbb" autoCapitalize="none" autoCorrect={false} keyboardType="url" accessibilityLabel="HUD WHIP URL" />
      </>}
      <Button title={active ? 'Stop Broadcast' : 'Start Broadcast'} onPress={toggle}
        disabled={pending || (!active && !url.trim())} />
      <Text style={styles.status} accessibilityLiveRegion="polite">Broadcast: {status.state}{status.message ? ` Â· ${status.message}` : ''}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  panel: { position: 'absolute', left: 12, right: 12, bottom: 8, backgroundColor: 'rgba(0,0,0,0.65)', borderRadius: 8, padding: 6 },
  input: { color: 'white', borderBottomWidth: 1, borderColor: '#888', padding: 5, fontSize: 12 },
  status: { color: 'white', fontSize: 11, textAlign: 'center' },
});
