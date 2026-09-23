import { darkTheme, lightTheme } from '@rainbow-me/rainbowkit'

/// Alt-UI RainbowKit theme (round 2, feature 5). Built on the stock dark/light
/// theme for the resolved mode so any structural default stays sane, then EVERY
/// key of the ThemeVars contract (29 colors, 6 shadows, 1 font, 5 radii,
/// 1 blur) is overridden with alt tokens: colors point at the site's CSS
/// variables, which flip with html[data-theme], so one mapping covers day and
/// night. Radii collapse to 0 (square), shadows become hard pixel offsets with
/// no blur, and the overlay scrim matches the site's .modal-backdrop. No stock
/// RainbowKit color survives in either mode.
export function altRainbowTheme(mode: 'dark' | 'light') {
  return {
    ...(mode === 'dark' ? darkTheme() : lightTheme()),
    colors: {
      accentColor: 'var(--green)',
      accentColorForeground: 'var(--green-ink)',
      actionButtonBorder: 'var(--line)',
      actionButtonBorderMobile: 'var(--line)',
      actionButtonSecondaryBackground: 'var(--raised)',
      closeButton: 'var(--muted)',
      closeButtonBackground: 'var(--raised)',
      connectButtonBackground: 'var(--raised)',
      connectButtonBackgroundError: 'var(--red)',
      connectButtonInnerBackground: 'var(--panel)',
      connectButtonText: 'var(--ink)',
      connectButtonTextError: 'var(--ink)',
      connectionIndicator: 'var(--green)',
      downloadBottomCardBackground: 'var(--panel)',
      downloadTopCardBackground: 'var(--raised)',
      error: 'var(--red)',
      generalBorder: 'var(--line)',
      generalBorderDim: 'var(--line)',
      menuItemBackground: 'var(--raised)',
      modalBackdrop: 'rgba(2,9,14,.72)',
      modalBackground: 'var(--panel)',
      modalBorder: 'var(--line)',
      modalText: 'var(--ink)',
      modalTextDim: 'var(--muted)',
      modalTextSecondary: 'var(--muted)',
      profileAction: 'var(--raised)',
      profileActionHover: 'var(--line)',
      profileForeground: 'var(--panel)',
      selectedOptionBorder: 'var(--green)',
      standby: 'var(--amber)',
    },
    fonts: {
      body: 'var(--body)',
    },
    radii: {
      actionButton: '0',
      connectButton: '0',
      menuButton: '0',
      modal: '0',
      modalMobile: '0',
    },
    shadows: {
      connectButton: '3px 3px 0 var(--shadow)',
      dialog: '5px 5px 0 var(--shadow)',
      profileDetailsAction: '3px 3px 0 var(--shadow)',
      selectedOption: '2px 2px 0 var(--shadow)',
      selectedWallet: '2px 2px 0 var(--shadow)',
      walletLogo: '2px 2px 0 var(--shadow)',
    },
    blurs: {
      // site scrim uses blur(8px); 'small' preset (blur(4px)) is the closest
      // sanctioned step — resolved value, not the preset name
      modalOverlay: 'blur(4px)',
    },
  }
}
