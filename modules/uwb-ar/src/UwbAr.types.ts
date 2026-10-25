import type { ViewProps } from 'react-native';

/** One nearby phone, as seen from this phone's camera. */
export type UwbPeer = {
  id: string;
  name: string;
  /** Meters. Present whenever UWB has a reading. */
  distance?: number;
  /** True once camera assistance has locked direction. */
  hasPosition: boolean;
  /** This peer's session uses camera assistance (iPhone 14+); otherwise direction comes from UWB alone. */
  cameraAssist: boolean;
  /** Camera assistance has reported in for this peer. */
  assistActive: boolean;
  /** Peer is in front of the camera (x/y are valid on-screen points). */
  inFront: boolean;
  /** Inside the tag insets: the native view is drawing its name tag, so no edge arrow is needed. */
  onScreen: boolean;
  /** Screen position in points, relative to the view. */
  x: number;
  y: number;
  /** Unit direction toward the peer on screen (y down). Use for edge arrows. */
  dirX: number;
  dirY: number;
  /** What the user should do to get a direction lock, e.g. "Sweep phone slowly left and right". */
  guidance?: string;
  /** No UWB reading for 2+ seconds. */
  stale: boolean;
};

export type UwbStatus = {
  status: string;
  /** This iPhone can find direction (UWB alone or with camera assistance), not just distance. */
  directionSupported: boolean;
  uwbSupported: boolean;
};

export type UwbArViewProps = ViewProps & {
  displayName?: string;
  /** [top, bottom, side] margins kept clear for the HUD. Peers outside them get an edge arrow. */
  tagInsets?: [number, number, number];
  onPeers?: (event: { nativeEvent: { peers: UwbPeer[] } }) => void;
  onStatus?: (event: { nativeEvent: UwbStatus }) => void;
};
