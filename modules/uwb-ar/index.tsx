import * as React from 'react';
import { requireNativeModule, requireNativeView } from 'expo';
import type { UwbArViewProps } from './src/UwbAr.types';

export * from './src/UwbAr.types';

const NativeModule = requireNativeModule('UwbAr');
const NativeView: React.ComponentType<UwbArViewProps> = requireNativeView('UwbAr');

/** True on iPhones with a UWB chip (iPhone 11 or newer, not SE). */
export function isUwbSupported(): boolean {
  return NativeModule.isSupported();
}

/** Full camera view that ranges nearby phones over UWB and reports where they are on screen. */
export function UwbArView(props: UwbArViewProps) {
  return <NativeView {...props} />;
}
