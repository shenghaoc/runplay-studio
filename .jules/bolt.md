## 2024-06-25 - DateFormatter Initialization Overhead in Parsing Loops
**Learning:** Instantiating `ISO8601DateFormatter` on every trackpoint parsed in GPX/TCX files causes significant overhead and object churn in Swift.
**Action:** Always cache `DateFormatter` instances as static properties when they are used inside large loops, especially in file importers parsing thousands of nodes.
