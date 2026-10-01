# Design Exploration (Gemini/Antigravity): The Battery Gauge

**Concept**
1. We treat each account's capacity like a device battery, visualizing both the weekly baseline and the 5-hour rolling short-term charge as physical bars.
2. The design ruthlessly prioritizes "what should I do next?" by sorting accounts by their availability and explicitly recommending one top action.
3. Instead of bombarding the user with technical units or percentages, we translate state into plain words ("Plenty of room", "Runs out before reset").
4. Visual clutter is minimized by using high-contrast brand colors and single letters for provider identities instead of literal trademark logos.
5. The result is a glanceable interface that feels native to the OS, mirroring the clarity and calmness of Apple's own Battery and Screen Time widgets.

**What I dropped on purpose**
- Exact token counts, "3.6x pace" jargon, and raw usage percentages. They add cognitive load without changing the user's immediate decision.
- Repetitive data on the Deadlines page. It's now strictly grouped into urgent "Running out" warnings and upcoming "Next Resets".
- Provider trademark logos. Distilled into colored circular icons with single letters to remain clean and avoid trademark embedding concerns while keeping identity obvious.

**3-second glance check result**
- **Small Widget:** Instantly reads "You're OK" and the large blue "G" immediately points me to use Gemini next.
- **Medium Widget:** The red pill immediately alerts me that 1 account is running out, while the split layout clearly hands me Gemini as the fallback.
- **Large Widget:** The clear grouping of "Recommended Next" vs "Warnings" makes it obvious that OpenAI Research is out of capacity, but Gemini and Claude are ready to go.
- **Mac Overview:** The visual progress tracks instantly draw the eye to the red 5-hour bar for OpenAI Research; the plain-text summary at the top gives the final verdict before I even read the cards.
- **Mac Deadlines:** The separated top red card makes it impossible to miss that OpenAI Research will die in 30 mins, while the rest are safely queued as future resets.
