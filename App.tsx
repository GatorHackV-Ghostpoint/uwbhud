import { useMemo, useState } from 'react';
import {
  Modal, Pressable, ScrollView, StatusBar, StyleSheet, Text, TextInput, useWindowDimensions, View,
} from 'react-native';
import { isUwbSupported, UwbArView, type UwbPeer, type UwbStatus } from './modules/uwb-ar';
import { BroadcastControls } from './modules/uwb-ar/BroadcastControls';

// Screen margins the HUD keeps clear (top status bar, bottom panel). Inside them the native view
// draws each peer's name tag; outside them we draw an edge arrow.
const INSET = { top: 130, bottom: 150, side: 30 };
const TAG_INSETS: [number, number, number] = [INSET.top, INSET.bottom, INSET.side];

export default function App() {
  const [peers, setPeers] = useState<UwbPeer[]>([]);
  const [status, setStatus] = useState<UwbStatus | null>(null);
  const [pairingCode, setPairingCode] = useState(''); // '' = automatic
  const [menuOpen, setMenuOpen] = useState(false);
  const [resetKey, setResetKey] = useState(0);
  const [name] = useState(() => 'Phone-' + Math.random().toString(36).slice(2, 6).toUpperCase());
  const supported = useMemo(() => isUwbSupported(), []);

  if (!supported) {
    return (
      <View style={[styles.fill, styles.center]}>
        <Text style={styles.big}>This iPhone has no UWB chip.</Text>
        <Text style={styles.small}>Needs iPhone 11 or newer (not SE).</Text>
      </View>
    );
  }

  const offScreen = peers.filter((p) => p.hasPosition && !p.stale && !p.onScreen);
  const waiting = peers.filter((p) => !p.hasPosition || p.stale);

  return (
    <View style={styles.fill}>
      <StatusBar barStyle="light-content" />
      <UwbArView
        style={StyleSheet.absoluteFill}
        displayName={name}
        pairingCode={pairingCode}
        resetKey={resetKey}
        tagInsets={TAG_INSETS}
        onPeers={(e) => setPeers(e.nativeEvent.peers)}
        onStatus={(e) => setStatus(e.nativeEvent)}
      />

      {offScreen.map((p) => (
        <EdgeArrow key={p.id} peer={p} />
      ))}

      {/* One row so the pairing button always matches the status bar's height. */}
      <View style={styles.topBar}>
        <View style={styles.topCard}>
          <Text style={styles.cardText}>
            {name} · {status?.status ?? 'Starting…'}
          </Text>
          {status && !status.directionSupported && (
            <Text style={styles.warn}>This iPhone can measure distance but not direction</Text>
          )}
        </View>

        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Pairing"
          onPress={() => setMenuOpen(true)}
          style={styles.pairButton}
        >
          <Text style={styles.pairIcon}>⇄</Text>
          {pairingCode !== '' && <Text style={styles.pairBadge}>{pairingCode}</Text>}
        </Pressable>
      </View>

      <PairingMenu
        visible={menuOpen}
        code={pairingCode}
        status={status}
        onCode={setPairingCode}
        onReset={() => setResetKey((k) => k + 1)}
        onClose={() => setMenuOpen(false)}
      />

      {waiting.length > 0 && (
        <View style={[styles.card, styles.bottom]}>
          {waiting.map((p) => (
            <Text key={p.id} style={styles.cardText}>
              {p.name}: {formatDistance(p.distance)}
              {p.stale
                ? ' (signal lost)'
                : p.distance == null
                  ? '. Waiting for UWB…'
                  : `. ${p.guidance ?? directionHint(p)}`}
            </Text>
          ))}
        </View>
      )}
      <BroadcastControls />
    </View>
  );
}

/**
 * Pairing sheet. Automatic connects to any nearby phone running the app; with a code, only phones
 * using the same code connect, so you get exactly the phone you mean, even in a room full of them.
 */
function PairingMenu({ visible, code, status, onCode, onReset, onClose }: {
  visible: boolean;
  code: string;
  status: UwbStatus | null;
  onCode: (code: string) => void;
  onReset: () => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState('');
  const join = () => {
    if (draft.length >= 4) {
      onCode(draft);
      setDraft('');
    }
  };

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <View style={styles.sheetBackdrop}>
        <View style={styles.sheet}>
          <View style={styles.sheetHeader}>
            <Text style={styles.sheetTitle}>Pairing</Text>
            <Pressable accessibilityRole="button" accessibilityLabel="Close" onPress={onClose} hitSlop={12}>
              <Text style={styles.sheetClose}>✕</Text>
            </Pressable>
          </View>

          {code ? (
            <>
              <Text style={styles.sheetLabel}>Pairing code</Text>
              <Text style={styles.code}>{code}</Text>
              <Text style={styles.sheetHint}>Enter this code on the other phone. Only phones using it will connect.</Text>
            </>
          ) : (
            <Text style={styles.sheetHint}>Automatic: connects to any nearby phone running UWBHud.</Text>
          )}

          <View style={styles.row}>
            <Pressable
              accessibilityRole="button"
              style={styles.button}
              onPress={() => onCode(String(Math.floor(1000 + Math.random() * 9000)))}
            >
              <Text style={styles.buttonText}>{code ? 'New code' : 'Create code'}</Text>
            </Pressable>
            {code !== '' && (
              <Pressable accessibilityRole="button" style={[styles.button, styles.buttonQuiet]} onPress={() => onCode('')}>
                <Text style={styles.buttonText}>Use automatic</Text>
              </Pressable>
            )}
          </View>

          <View style={styles.row}>
            <TextInput
              value={draft}
              onChangeText={(t) => setDraft(t.replace(/\D/g, '').slice(0, 6))}
              onSubmitEditing={join}
              placeholder="Enter code"
              placeholderTextColor="#888"
              keyboardType="number-pad"
              returnKeyType="done"
              style={styles.input}
            />
            <Pressable
              accessibilityRole="button"
              disabled={draft.length < 4}
              style={[styles.button, draft.length < 4 && styles.buttonDisabled]}
              onPress={join}
            >
              <Text style={styles.buttonText}>Join</Text>
            </Pressable>
          </View>

          <Pressable accessibilityRole="button" style={[styles.button, styles.buttonQuiet, styles.resetButton]} onPress={onReset}>
            <Text style={styles.buttonText}>Reset pairing</Text>
          </Pressable>

          <Text style={styles.sheetLabel}>{status?.status ?? 'Starting…'}</Text>
          <ScrollView style={styles.timeline}>
            {(status?.timeline ?? []).map((line, i) => (
              <Text key={i} style={styles.timelineText}>{line}</Text>
            ))}
          </ScrollView>
        </View>
      </View>
    </Modal>
  );
}

/** Arrow pinned to the screen edge for a peer that's off screen (the native view draws on-screen tags). */
function EdgeArrow({ peer }: { peer: UwbPeer }) {
  const { width, height } = useWindowDimensions();

  // Walk from screen center along the peer's direction until we hit the safe-area edge.
  const cx = width / 2, cy = height / 2;
  const rx = (width / 2 - INSET.side - 40) / Math.max(Math.abs(peer.dirX), 1e-4);
  const ry = (height / 2 - INSET.top) / Math.max(Math.abs(peer.dirY), 1e-4);
  const r = Math.min(rx, ry);
  const angle = Math.atan2(peer.dirY, peer.dirX); // 0 = right, positive = clockwise (y down)

  return (
    <View pointerEvents="none" style={[styles.edge, { left: cx + peer.dirX * r - 55, top: cy + peer.dirY * r - 30 }]}>
      <Text style={[styles.arrow, { transform: [{ rotate: `${angle}rad` }] }]}>➤</Text>
      <Text style={styles.edgeText}>{peer.name}</Text>
      <Text style={styles.edgeText}>
        {peer.estimated ? '~' : ''}
        {formatDistance(peer.distance)}
      </Text>
    </View>
  );
}

function directionHint(p: UwbPeer) {
  if (!p.cameraAssist) return 'Point the back of your phone toward them';
  return p.assistActive ? 'Finding direction…' : 'Finding direction… (camera assist not responding)';
}

function formatDistance(m?: number) {
  if (m == null) return '—';
  return m < 10 ? `${m.toFixed(2)} m` : `${m.toFixed(1)} m`;
}

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: 'black' },
  center: { alignItems: 'center', justifyContent: 'center', padding: 24 },
  big: { color: 'white', fontSize: 20, fontWeight: '700', textAlign: 'center' },
  small: { color: '#ccc', fontSize: 15, marginTop: 8 },
  card: {
    position: 'absolute', left: 12, right: 12,
    backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 12, padding: 10,
  },
  topBar: {
    position: 'absolute', top: 56, left: 12, right: 12,
    flexDirection: 'row', alignItems: 'stretch', gap: 8,
  },
  topCard: {
    flex: 1, minHeight: 44, justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 12, padding: 10,
  },
  bottom: { bottom: 40 },
  cardText: { color: 'white', fontSize: 14, fontWeight: '600' },
  warn: { color: '#ffcc00', fontSize: 13, marginTop: 4 },
  edge: {
    position: 'absolute', width: 110, alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: 12, paddingVertical: 6,
  },
  arrow: { color: '#34c759', fontSize: 22 },
  edgeText: { color: 'white', fontSize: 12, fontWeight: '600' },
  pairButton: {
    width: 48, minHeight: 44, alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 12,
  },
  pairIcon: { color: 'white', fontSize: 22, fontWeight: '700' },
  pairBadge: { color: '#34c759', fontSize: 10, fontWeight: '700' },
  sheetBackdrop: { flex: 1, justifyContent: 'flex-end', backgroundColor: 'rgba(0,0,0,0.35)' },
  sheet: {
    backgroundColor: '#1c1c1e', borderTopLeftRadius: 20, borderTopRightRadius: 20,
    padding: 20, paddingBottom: 40, maxHeight: '80%',
  },
  sheetHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 },
  sheetTitle: { color: 'white', fontSize: 20, fontWeight: '700' },
  sheetClose: { color: '#aaa', fontSize: 20 },
  sheetLabel: { color: '#aaa', fontSize: 13, fontWeight: '600', marginTop: 8 },
  sheetHint: { color: '#ccc', fontSize: 14, marginTop: 4 },
  code: { color: 'white', fontSize: 44, fontWeight: '800', letterSpacing: 8, marginVertical: 4 },
  row: { flexDirection: 'row', gap: 10, marginTop: 14 },
  button: {
    flex: 1, minHeight: 44, borderRadius: 10, backgroundColor: '#34c759',
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 12,
  },
  buttonQuiet: { backgroundColor: '#3a3a3c' },
  resetButton: { flex: 0, marginTop: 14 },
  buttonDisabled: { opacity: 0.4 },
  buttonText: { color: 'white', fontSize: 15, fontWeight: '700' },
  input: {
    flex: 2, minHeight: 44, borderRadius: 10, backgroundColor: '#2c2c2e',
    color: 'white', fontSize: 18, paddingHorizontal: 12, letterSpacing: 4,
  },
  timeline: { marginTop: 6, maxHeight: 220 },
  timelineText: { color: '#ddd', fontSize: 12, fontFamily: 'Menlo' },
});
