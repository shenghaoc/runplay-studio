# Watch-folder Settings design

The app owns one typed Settings tab selection. The File command updates
that selection and invokes SwiftUI's Settings action in that order. The
Settings tab selection binds to the same state. Each visible Remove Folder
button delegates to the existing coordinator removal; no library operation
is performed. The new label and retention notice use a watch-folder string
catalog in the existing Studio resource bundle.
