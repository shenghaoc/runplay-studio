# Prompt: Add Export Summary Feature

## Context

Users want to export their run analysis for sharing or record-keeping.

## Task

Implement export functionality:

1. **PNG Export** - Export current view as PNG:
   - 3D route scene
   - Charts with current state
   - Map view
   - Summary overlay

2. **CSV Export** - Export data as CSV:
   - Route points with all metrics
   - Splits table
   - Summary statistics

3. **Share sheet** - Use macOS share sheet for:
   - Save to Files
   - AirDrop
   - Messages
   - Mail

4. **Export dialog** - Add export options:
   - File format selection
   - Quality/resolution settings
   - Include/exclude sections

## Files to Create/Modify

- `RunPlayStudio/Sources/Services/ExportService.swift` (create)
- `RunPlayStudio/Sources/Views/ExportView.swift` (create)
- `RunPlayStudio/Sources/Views/WorkoutDetailView.swift`

## Acceptance Criteria

- [ ] PNG export works for all views
- [ ] CSV export includes all data
- [ ] Share sheet integrates with macOS
- [ ] Export dialog is user-friendly
- [ ] Exported files are valid
