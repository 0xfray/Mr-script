@third_leg_ on discord to purchase

# Universal Auto-Trade
## Autonomous trading system for the My Restaurant Trading Plaza

### Full Automation
- Advertises your live stock in public chat on a rotating, rate-limited schedule
- Auto-invites nearby players, batched with per-player cooldowns
- Detects and skips players the server marks mid-trade — no wasted invites
- Auto-accepts incoming invites and picks up windows opened by buyers
- Drives the entire trade start to finish with zero input
- Continues through the full order queue until every quantity is filled
- Optional auto-start on load, so a rejoin resumes trading on its own

### Trade Execution
- Role-aware trade reading — correctly identifies which side is yours every time
- Adds items and verifies each one actually attached, retrying anything dropped
- Adaptive add pacing that self-throttles the moment the server rejects a piece
- Packs as many complete units per trade as the item limit allows
- Trims surplus items by exact UID so the buyer pays for precisely what they get
- Posts your price on a timed delay, then re-posts while the buyer is deciding
- Reads the trade chatlog back to confirm your message actually landed
- Parses buyer requests in natural language: "2 sets", "gimme 3", "3x", "two"
- Automatically scales the offer to what the buyer can afford
- Confirms the moment the buyer commits, or once their gems settle
- Re-confirms automatically if a state change clears your confirmation
- Verifies every sale against your real gem balance before recording it

### Orders and Pricing
- Sell-order queue with per-order quantity, price and live fill progress
- Set support: bundle multiple items into one sellable unit at one price
- Automatic pricing from a live value list with configurable markup
- Demand-aware pricing that raises margin on high-demand items
- Per-item overrides for value, markup and negotiation band
- Manual prices always take precedence — your number is never overridden
- Hard price floor on automatic pricing, immune to a stale or corrupted feed
- One-click order book generation from your entire inventory
- Quantity shortcuts, live item search, and instant order management
- Fully editable chat and in-trade message templates with dynamic tokens
- Optional auto-buyer that flips to purchasing once you hit your gem cap

### Safety
- Test Mode enabled by default: performs every step except the final confirm
- Re-validates the buyer's gems in the same instant it confirms
- Aborts immediately if a buyer reduces their offer after committing
- Never confirms blind when the buyer's confirmation state can't be read
- Records a sale only when your gem balance genuinely increases
- Handles each trade window exactly once — items are never re-added
- Per-player cooldowns and a persistent blocklist
- Gem cap with hysteresis to prevent mode flip-flopping
- Place-locked: refuses to run outside the supported trading hubs
- Every action fails closed, with a logged reason

### Privacy Mode
- Replaces your username with a randomised alias everywhere on screen
- Hides the player list, every overhead nameplate, and your avatar
- Masks your name inside the game's own UI, not just Roblox's
- Other players get consistent aliases too, so nothing in your screenshots identifies anyone
- Aliases stay stable for the whole session, and reset on each launch
- Fully reversible - toggle it off and everything returns to normal

### Demo Chat
- Generates realistic plaza chatter so a demo never looks like a dead server
- Lines reference the items you're actually selling
- Rendered with a client-only API - **nothing is ever sent**, nobody else sees a single line
- Senders are invented aliases, never real players
- Adjustable frequency, with a live transcript inside the panel

-# Both are off by default. Privacy Mode masks your own view - other players in the server still see your real name.

  ### Built to Run Unattended
- Anti-AFK defeats the idle disconnect
- Automatic reconnect and rejoin after a drop
- Watchdog supervision restarts the trade loop after any error
- Orders, statistics and pricing persist to disk and survive a rejoin
- Value list auto-refreshes on a timer, with offline cache fallback
- Discord webhook alerts for sales, gem cap, disconnects and errors
- Saved preferences always survive an update

### Performance
- Event-driven: reacts to the game's own signals instead of a fixed timer
- Falls back to polling automatically — never trades responsiveness for speed
- Inventory reads cached and scoped: hundreds of calls per trade reduced to a few
- Monotonic high-precision timing on every deadline
- Roughly twice the trade throughput of the previous build

### Interface and Diagnostics
- Clean multi-tab panel with hotkey toggle and a floating reopen button
- Live dashboard: gems, sales, gems per hour, units remaining, current trade
- One-click debug report copied straight to your clipboard
- Full environment probe covering remotes, inventory, chat and trade state
- Continuous health telemetry on every network call

### Engineering
- Modular source, compiled into a single self-contained script
- 363 automated tests covering all pricing, ordering and safety logic
