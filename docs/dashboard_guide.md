# Building the Tableau Public dashboard

Everything is done in the browser (Tableau Public web authoring); nothing is installed.
Tableau Public occasionally renames buttons, so if a label differs slightly, look for the closest match.

## 0. Produce the data (in the codespace)

```bash
source .venv/bin/activate
dbt build
python scripts/export_for_tableau.py
```

This writes three files to `exports/`. In the codespace Explorer, right-click each one and choose **Download**:

| File | One row per | Used for |
|---|---|---|
| `screen_latest.csv` | company, latest month-end | View 1: today's screen |
| `restatements_by_metric.csv` | metric | View 2: the restatement story |
| `screen_history.csv` | company and month-end | View 3: point-in-time history |

## 1. Create an account and start a workbook

1. Go to **public.tableau.com**, click **Sign Up** (free), and verify your email. Use your personal email.
2. Fill in your profile: name, photo, bio, and links to GitHub and LinkedIn. Recruiters will see this page.
3. Click **Create** (or **Create a Viz**) in the top bar. The web editor opens.
4. Upload **screen_latest.csv** (drag it into the window or click to browse).
5. To add the other two files: **Data → New Data Source** (or the **+** next to the data source name), and upload each one.
   Keep them as **separate data sources**. Each view uses only one file, so no joins are needed.

## 2. View 1 — "Today's screen" (data source: screen_latest)

1. Rename the sheet (double-click the tab at the bottom): **Today's Screen**.
2. Drag **Ticker** to **Rows** and **F-Score** to **Columns**. Tableau draws a horizontal bar per company.
3. Sort: click the sort icon on the F-Score axis so the highest score is on top.
4. Drag **Complete Score** to **Color**. Edit colors: `true` = dark blue, `false` = light grey.
   Readers can then see which scores rest on fewer than 9 known signals.
5. Drag **F-Score** to **Label** so each bar shows its number.
6. Drag these to **Tooltip**: Company, Sector, Signals Available, Gross Margin, Accruals Ratio, Total Debt ($B), Debt Source.
7. Drag **Sector** to **Filters**, select all, then right-click it → **Show Filter**.
8. Format percentages: right-click **Gross Margin** in the Data pane → **Default Properties → Number Format → Percentage**, 1 decimal.
   Do the same for the other margins.

## 3. View 2 — "Restatement story" (data source: restatements_by_metric)

1. New sheet (the icon next to the bottom tabs), rename it **What Changed After Publication**.
2. Drag **Metric** to **Rows**.
3. Drag **Genuine Revisions** to **Columns**, then drop **Tag Switches** and **Scale Error Corrections** onto the
   same axis (Tableau switches to **Measure Values**).
4. Drag **Measure Names** to **Color**. Colors: Genuine Revisions = dark blue, Tag Switches = orange, Scale Error Corrections = red.
5. Sort metrics so the most-restated is on top.
6. Title: *Restatements by metric: genuine revisions vs. data artifacts*.

## 4. View 3 — "Point-in-time history" (data source: screen_history)

1. New sheet, rename it **F-Score Through Time**.
2. Drag **As Of Date** to **Columns**. Click its dropdown and choose the **continuous Month** option (the green one).
3. Drag **F-Score** to **Rows** twice, so there are two F-Score charts.
4. In the **Marks** card for the **first** F-Score, set the mark type to **Line**.
5. In the **Marks** card for the **second** F-Score, set the mark type to **Circle**, then drag **Change Reason** to **Color**.
   Colors: No change = very light grey (or set its opacity low), New annual report = blue,
   Revised data for same fiscal year = red.
6. Right-click the second F-Score pill on Rows → **Dual Axis**, then right-click the right axis → **Synchronize Axis**
   and hide it (**uncheck Show Header**).
7. Drag **Ticker** to **Filters**, choose one company (e.g. KO), then right-click → **Show Filter** and set it to
   **Single Value (dropdown)**.
8. Add **Fiscal Year End**, **Signals Available**, **F-Score Change** and **Change Reason** to **Tooltip**.

The red circles are the point of the project: months where a company's score changed *without* a new annual
report, because a previously published number was revised. A warehouse that keeps only the latest values can't show them.

## 5. The dashboard

1. Click the **New Dashboard** icon at the bottom.
2. Size: **Automatic** (or Fixed 1200 × 900).
3. Drag a **Text** object to the top and write:
   - Title: **Point-in-Time Equity Screen**
   - Subtitle: *Piotroski F-scores for 28 US large caps, using only what was public on each month-end. Source: SEC EDGAR XBRL.*
4. Drag **Today's Screen** onto the left half, **F-Score Through Time** onto the right half, and
   **What Changed After Publication** below.
5. Make the Sector filter apply only to Today's Screen (it does by default because it comes from that data source).
6. Add a small text box at the bottom: *Built with Python, dbt and DuckDB. Code and methodology:
   github.com/rajib-k-das/point-in-time-fundamentals*.

## 6. Publish

1. **File → Save** (or **Publish**). Name it **Point-in-Time Equity Screen**.
2. Open the published viz from your profile and check it in a private browser window.
3. Copy its link. Add it to the project README, your GitHub profile README, and LinkedIn **Featured**.
   Then take a screenshot of the dashboard and save it as `docs/dashboard.png` for the README.

Everything on Tableau Public is public. These files contain only public SEC data.
