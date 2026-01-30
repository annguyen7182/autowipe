# Autowipe Project Evolution

## 📖 The Story: Building the Robot Operator

This project didn't start as a fully autonomous system. It was built layer by layer, solving one specific bottleneck at a time.

### Phase 1: The "Locator" (Port Mapping)
**The Challenge:** We had 24 drives plugged into a rig, but Windows just listed them as "Disk 0" through "Disk 23". Finding physically bad drives required a magnifying glass to match serial numbers on labels.
**The Solution:**
*   I discovered that the **`PNPDeviceID`** in Windows contains the physical USB port path.
*   I built a small app that simply mapped these IDs to physical slot numbers (1-24).
*   **Result:** Instantly knowing that "Disk 5 is in Slot 12". No more magnifying glasses.

### Phase 2: The "Tracker" (HDS Window Grid)
**The Challenge:** Once the specific drive was located, we still had to find its corresponding "Surface Test" window hidden among 24 open windows on the desktop.
**The Solution:**
*   I created a **Grid Dashboard** (as documented in *Autowipe 3.1*).
*   The code learned to find all open Hard Disk Sentinel (HDS) windows.
*   It matched each window's Title (e.g., "Disk 5") to the physical port from Phase 1.
*   **Result:** A live dashboard showing exactly which window belonged to which slot.

### Phase 3: The "Judge" (Verdict Analysis)
**The Challenge:** Tracking was good, but we still had to manually check each window to see if it Passed or Failed. A drive sitting at "100%" might actually have hidden errors.
**The Solution:**
*   I built an **Analysis Engine** to read the contents of the Surface Test windows.
*   Instead of reading heavy text, I used a clever "Length Check":
    *   **PASS:** Short log text (no errors).
    *   **FAIL:** Long log text (error messages present).
*   **Result:** The system could now give a definitive **Green (PASS)** or **Red (FAIL)** verdict automatically.

### Phase 4: The "Automator" (Full Autopilot)
**The Challenge:** We still had to manually click "Start," "Save," and "Close" for every single drive.
**The Solution:**
*   I started building automation step-by-step:
    1.  **Auto-Refresh:** Clicking the refresh button to detect new drives.
    2.  **Auto-Save:** Generating and saving the HTML reports.
    3.  **Auto-Wipe:** Launching the surface tests automatically.
    4.  **Batch Logic:** Adding timers so the system waits for the user to finish plugging in drives before starting.
*   **Result:** A fully autonomous "Robot Manager" that runs the entire production floor with minimal human intervention.

### Phase 5: The "Architect" (Refactoring the Monolith)
**The Challenge:** As automation features grew (pop-up blockers, auto-save, batch timers), the script became a massive **"Monolith"** (over 3,200 lines in a single file).
*   **Pain Point:** Debugging was a nightmare. Changing one line in the "HDS Clicker" logic risked breaking the "GUI Grid" logic because everything was tangled together.
*   **The Solution:** I completely refactored the codebase into a **Modular Architecture**.
    *   **Core:** Handles config and logging.
    *   **Watcher:** Handles the "Verdict" logic.
    *   **HdsControl:** Handles the "Clicking" logic.
    *   **Automation:** Handles the "Timing" logic.
    *   **Gui:** Handles the visual display.
*   **Result:** A clean, stable, and maintainable codebase (v5.5) where features can be upgraded independently without breaking the whole system.

---

## 🏗️ Architecture

The project follows a modular event-driven design:

```
Autowipe_Redux/
├── src/
│   ├── Autowipe.ps1       # Entry point & Module Loader
│   └── modules/
│       ├── Core.ps1       # Configuration, Logging, CSV Database
│       ├── HdsControl.ps1 # "The Hands": Clicks buttons, handles Windows
│       ├── Watcher.ps1    # "The Eyes": Maps ports, judges Pass/Fail
│       ├── Automation.ps1 # "The Brain": Timers, Batch Logic, Scheduling
│       └── Gui.ps1        # "The Face": WinForms Interface
```

## 📊 Performance Metrics

| Metric | Manual Process | Autowipe v5 | Improvement |
| :--- | :--- | :--- | :--- |
| **Prep Time (360 Drives)** | 4 Hours | 1 Hour | **4x Faster** |
| **Missed Failures** | Frequent (Human Error) | 0% (Code Verdict) | **100% Reliability** |
| **Staff Required** | 1 per Rig | 1 per 5 Rigs | **5x Efficiency** |
