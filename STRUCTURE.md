```
not-another-sandbox/
├── install.sh              # Interactive installer (all modes)
├── README.md
├── STATUS.md
├── docs/
│   └── design.md
├── skills/
│   ├── nas-elevate/        # Runtime privilege elevation
│   └── nas-setup-guide/    # Setup guidance (README reference)
├── scripts/                # Direct/sodo shell implementations
│   ├── nmux-sodo.sh
│   └── nmux-verify.sh
└── relay/                  # Relay mode Go source (optional)
    ├── go.mod
    ├── cmd/
    │   ├── nmux/           # CLI with crypto/rand tokens
    │   └── nmuxd/          # Minimal daemon
    └── pkg/
```

**Dependencies by mode:**
- Direct: bash + tmux
- Sodo: bash + tmux + sudo
- Relay: Go 1.21+ (or download pre-built binary)
