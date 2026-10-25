import { memo, useCallback, useEffect, useMemo, useState } from 'react';
import {
  Animated, LayoutAnimation, Linking, Modal, Pressable, ScrollView, StatusBar, StyleSheet, Text, TextInput,
  useWindowDimensions, View, type StyleProp, type ViewProps, type ViewStyle,
} from 'react-native';
import { GlassView, isLiquidGlassAvailable } from 'expo-glass-effect';
import { isUwbSupported, UwbArView, type UwbPeer, type UwbStatus } from './modules/uwb-ar';
import { BroadcastPanel, SERVER, useBroadcast, type Broadcast } from './modules/uwb-ar/BroadcastControls';
import { WaypointControls } from './modules/uwb-ar/WaypointControls';

// Liquid Glass needs iOS 26+. Elsewhere panels fall back to translucent dark fills.
const GLASS = isLiquidGlassAvailable();

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
  // "Continue without UWB" hides the Bluetooth dialog until Bluetooth has been on again.
  const [bluetoothDismissed, setBluetoothDismissed] = useState(false);
  const [name] = useState(() => 'Phone-' + Math.random().toString(36).slice(2, 6).toUpperCase());
  const supported = useMemo(() => isUwbSupported(), []);
  const broadcast = useBroadcast();
  // Stable callbacks, so the memoized sheet and dialog don't re-render on every peer update (~30x/sec).
  const closeMenu = useCallback(() => setMenuOpen(false), []);
  const resetPairing = useCallback(() => setResetKey((k) => k + 1), []);
  const continueWithoutUwb = useCallback(() => setBluetoothDismissed(true), []);

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
  const bluetooth = status?.bluetooth ?? 'unknown';
  const bluetoothProblem = bluetooth === 'off' || bluetooth === 'unauthorized';
  const linked = peers.length > 0;   // linked to at least one phone: broadcasting is allowed
  const live = broadcast.status.state === 'live';

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
        onStatus={(e) => {
          setStatus(e.nativeEvent);
          if (e.nativeEvent.bluetooth === 'on') setBluetoothDismissed(false);
        }}
      />

      {offScreen.map((p) => (
        <EdgeArrow key={p.id} peer={p} />
      ))}

      {/* One row so the pairing button always matches the status bar's height. */}
      <View style={styles.topBar}>
        <Surface style={styles.topCard} fallback={styles.hudFill}>
          <Text style={styles.cardText}>
            {name} · {status?.status ?? 'Starting…'}
          </Text>
          {status && !status.directionSupported && (
            <Text style={styles.warn}>This iPhone can measure distance but not direction</Text>
          )}
          {bluetooth === 'off' && (
            <Text style={styles.warn}>Bluetooth off: no UWB. Yellow positions are rough estimates</Text>
          )}
        </Surface>

        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Pairing"
          onPress={() => setMenuOpen(true)}
          style={styles.pairButton}
        >
          <Surface style={styles.pairFill} fallback={styles.hudFill} pointerEvents="none" />
          <Text style={styles.pairIcon}>⇄</Text>
          {pairingCode !== '' && <Text style={styles.pairBadge}>{pairingCode}</Text>}
          {live && <View style={styles.liveDot} accessibilityLabel="Broadcasting" />}
        </Pressable>
      </View>

      {/* iOS shows one modal at a time, so this waits while the pairing sheet is open. */}
      <BluetoothDialog
        visible={bluetoothProblem && !bluetoothDismissed && !menuOpen}
        state={bluetooth}
        onContinue={continueWithoutUwb}
      />

      <PairingMenu
        visible={menuOpen}
        code={pairingCode}
        status={status}
        linked={linked}
        broadcast={broadcast}
        onCode={setPairingCode}
        onReset={resetPairing}
        onClose={closeMenu}
      />

      <View style={styles.bottomStack} pointerEvents="box-none">
        {waiting.length > 0 && (
          <View style={styles.card}>
            {waiting.map((p) =>
              p.uwbOffHere || p.uwbOffThere ? (
                <Text key={p.id} style={[styles.cardText, styles.noUwbText]}>
                  {p.name}: no UWB ({p.uwbOffHere ? 'Bluetooth is off on this phone' : 'Bluetooth is off on their phone'}).
                  Position unavailable
                </Text>
              ) : (
                <Text key={p.id} style={styles.cardText}>
                  {p.name}: {formatDistance(p.distance)}
                  {p.stale
                    ? ' (signal lost)'
                    : p.distance == null
                      ? '. Waiting for UWB…'
                      : `. ${p.guidance ?? directionHint(p)}`}
                </Text>
              ),
            )}
          </View>
        )}
        {/* Placing a waypoint means tapping the camera view, so these stay on screen rather than in the sheet. */}
        {broadcast.device && <WaypointControls server={SERVER} device={broadcast.device} />}
      </View>
    </View>
  );
}

/**
 * Link sheet with two modes. Pairing: automatic connects to any nearby phone running the app; with a code, only
 * phones using the same code connect, so you get exactly the phone you mean, even in a room full of them.
 * Broadcast: share this screen with the dashboard. It stays grayed out until a phone is linked.
 */
const PairingMenu = memo(function PairingMenu({ visible, code, status, linked, broadcast, onCode, onReset, onClose }: {
  visible: boolean;
  code: string;
  status: UwbStatus | null;
  linked: boolean;
  broadcast: Broadcast;
  onCode: (code: string) => void;
  onReset: () => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState('');
  const [tab, setTab] = useState<'pairing' | 'broadcast'>('pairing');
  // A running broadcast can always be reached (to stop it), even if the link has since dropped.
  const canBroadcast = linked || broadcast.active;
  const mode = tab === 'broadcast' && canBroadcast ? 'broadcast' : 'pairing';
  // The highlight slides between the two tab buttons; 0 = Pairing, 1 = Broadcast.
  const [slide] = useState(() => new Animated.Value(0));
  const [tabsWidth, setTabsWidth] = useState(0);
  const segment = Math.max((tabsWidth - TAB_PAD * 2 - TAB_GAP) / 2, 0);
  useEffect(() => {
    Animated.spring(slide, { toValue: mode === 'broadcast' ? 1 : 0, useNativeDriver: true, speed: 18, bounciness: 5 }).start();
  }, [mode, slide]);
  const select = (next: 'pairing' | 'broadcast') => {
    if (next === mode) return;
    // The two tabs differ in height: let the sheet grow or shrink smoothly instead of jumping.
    LayoutAnimation.configureNext(LayoutAnimation.create(260, LayoutAnimation.Types.easeInEaseOut, LayoutAnimation.Properties.opacity));
    setTab(next);
  };
  const join = () => {
    if (draft.length >= 4) {
      onCode(draft);
      setDraft('');
    }
  };

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <View style={styles.sheetBackdrop}>
        <Surface style={styles.sheet} fallback={styles.sheetFill}>
          <View style={styles.sheetHeader}>
            <Text style={styles.sheetTitle}>{mode === 'pairing' ? 'Pairing' : 'Broadcast'}</Text>
            <Pressable accessibilityRole="button" accessibilityLabel="Close" onPress={onClose} hitSlop={12}>
              <Text style={styles.sheetClose}>✕</Text>
            </Pressable>
          </View>

          <View style={styles.tabs} accessibilityRole="tablist" onLayout={(e) => setTabsWidth(e.nativeEvent.layout.width)}>
            <Animated.View
              pointerEvents="none"
              style={[styles.tabHighlight, {
                width: segment,
                transform: [{ translateX: slide.interpolate({ inputRange: [0, 1], outputRange: [0, segment + TAB_GAP] }) }],
              }]}
            />
            <Pressable
              accessibilityRole="tab"
              accessibilityState={{ selected: mode === 'pairing' }}
              style={styles.tab}
              onPress={() => select('pairing')}
            >
              <Text style={styles.tabText}>Pairing</Text>
            </Pressable>
            <Pressable
              accessibilityRole="tab"
              accessibilityState={{ selected: mode === 'broadcast', disabled: !canBroadcast }}
              disabled={!canBroadcast}
              style={[styles.tab, !canBroadcast && styles.tabDisabled]}
              onPress={() => select('broadcast')}
            >
              <Text style={styles.tabText}>Broadcast{broadcast.status.state === 'live' ? '  ●' : ''}</Text>
            </Pressable>
          </View>
          {!canBroadcast && <Text style={styles.tabHint}>Broadcast unlocks once another phone is paired.</Text>}

          {mode === 'broadcast' ? <BroadcastPanel broadcast={broadcast} /> : <>
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
          </>}
        </Surface>
      </View>
    </Modal>
  );
});

/**
 * Shown while Bluetooth is off (or the app can't check it). UWB needs Bluetooth, and without it iOS pauses every
 * ranging session, so this explains why and lets the user carry on with approximate (yellow) positions.
 */
const BluetoothDialog = memo(function BluetoothDialog({ visible, state, onContinue }: {
  visible: boolean;
  state: UwbStatus['bluetooth'];
  onContinue: () => void;
}) {
  const unauthorized = state === 'unauthorized';
  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onContinue}>
      <View style={styles.dialogBackdrop}>
        <Surface style={styles.dialog} fallback={styles.sheetFill}>
          <Text style={styles.sheetTitle}>{unauthorized ? 'Allow Bluetooth' : 'Turn on Bluetooth'}</Text>
          <Text style={styles.dialogText}>
            {unauthorized
              ? 'UWBHud needs Bluetooth permission to check that UWB can run. Allow Bluetooth for UWBHud in Settings.'
              : 'UWB distance and direction need Bluetooth. Turn it on in Settings → Bluetooth (Control Center alone may not be enough), and make sure Airplane Mode is off.'}
          </Text>
          <Text style={styles.dialogText}>
            Without it, other phones show in yellow: their position is a rough estimate, or unavailable.
          </Text>
          {unauthorized && (
            <Pressable accessibilityRole="button" style={[styles.button, styles.dialogButton]} onPress={() => void Linking.openSettings()}>
              <Text style={styles.buttonText}>Open Settings</Text>
            </Pressable>
          )}
          <Pressable accessibilityRole="button" style={[styles.button, styles.buttonQuiet, styles.dialogButton]} onPress={onContinue}>
            <Text style={styles.buttonText}>Continue without UWB</Text>
          </Pressable>
        </Surface>
      </View>
    </Modal>
  );
});

/** A panel: Liquid Glass where the system supports it, otherwise the given translucent fill. */
function Surface({ style, fallback, children, ...rest }: ViewProps & { fallback: StyleProp<ViewStyle> }) {
  return GLASS ? (
    <GlassView glassEffectStyle="regular" colorScheme="dark" style={style} {...rest}>{children}</GlassView>
  ) : (
    <View style={[style, fallback]} {...rest}>{children}</View>
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
      <Text style={[styles.arrow, peer.approximate && styles.arrowApproximate, { transform: [{ rotate: `${angle}rad` }] }]}>➤</Text>
      <Text style={styles.edgeText}>{peer.name}</Text>
      <Text style={styles.edgeText}>
        {peer.estimated || peer.approximate ? '~' : ''}
        {formatDistance(peer.distance)}
        {peer.uwbOffHere || peer.uwbOffThere ? ' · no UWB' : ''}
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

const TAB_PAD = 3;
const TAB_GAP = 3;

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: 'black' },
  center: { alignItems: 'center', justifyContent: 'center', padding: 24 },
  big: { color: 'white', fontSize: 20, fontWeight: '700', textAlign: 'center' },
  small: { color: '#ccc', fontSize: 15, marginTop: 8 },
  card: { backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 12, padding: 10 },
  bottomStack: { position: 'absolute', left: 12, right: 12, bottom: 40, gap: 8 },
  topBar: {
    position: 'absolute', top: 56, left: 12, right: 12,
    flexDirection: 'row', alignItems: 'stretch', gap: 8,
  },
  topCard: { flex: 1, minHeight: 44, justifyContent: 'center', borderRadius: 12, padding: 10 },
  hudFill: { backgroundColor: 'rgba(0,0,0,0.55)' },
  sheetFill: { backgroundColor: 'rgba(28,28,30,0.86)' },
  cardText: { color: 'white', fontSize: 14, fontWeight: '600' },
  warn: { color: '#ffcc00', fontSize: 13, marginTop: 4 },
  edge: {
    position: 'absolute', width: 110, alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: 12, paddingVertical: 6,
  },
  arrow: { color: '#34c759', fontSize: 22 },
  arrowApproximate: { color: '#ffcc00' },
  noUwbText: { color: '#ffcc00' },
  dialogBackdrop: { flex: 1, justifyContent: 'center', padding: 24, backgroundColor: 'rgba(0,0,0,0.6)' },
  dialog: { borderRadius: 16, padding: 20, borderWidth: 1, borderColor: '#ffcc00' },
  dialogText: { color: '#ddd', fontSize: 15, marginTop: 10, lineHeight: 21 },
  dialogButton: { flex: 0, marginTop: 14 },
  edgeText: { color: 'white', fontSize: 12, fontWeight: '600' },
  pairButton: { width: 48, minHeight: 44, alignItems: 'center', justifyContent: 'center', borderRadius: 12 },
  pairFill: { position: 'absolute', top: 0, right: 0, bottom: 0, left: 0, borderRadius: 12 },
  pairIcon: { color: 'white', fontSize: 22, fontWeight: '700' },
  pairBadge: { color: '#34c759', fontSize: 10, fontWeight: '700' },
  liveDot: { position: 'absolute', top: 6, right: 6, width: 8, height: 8, borderRadius: 4, backgroundColor: '#ff3b30' },
  tabs: { flexDirection: 'row', backgroundColor: 'rgba(118,118,128,0.24)', borderRadius: 10, padding: TAB_PAD, gap: TAB_GAP },
  tabHighlight: {
    position: 'absolute', top: TAB_PAD, bottom: TAB_PAD, left: TAB_PAD, borderRadius: 8,
    backgroundColor: 'rgba(255,255,255,0.18)',
  },
  tab: { flex: 1, minHeight: 36, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  tabDisabled: { opacity: 0.35 },
  tabText: { color: 'white', fontSize: 14, fontWeight: '700' },
  tabHint: { color: '#8e8e93', fontSize: 12, marginTop: 6 },
  sheetBackdrop: { flex: 1, justifyContent: 'flex-end', backgroundColor: 'rgba(0,0,0,0.35)' },
  // Floating card with even corners: Liquid Glass rounds all four, and the fallback matches it.
  sheet: { margin: 8, borderRadius: 28, padding: 20, paddingBottom: 28, maxHeight: '80%', overflow: 'hidden' },
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
