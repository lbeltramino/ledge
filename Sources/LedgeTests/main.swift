import Foundation

await CoreTests.run()
await IndexTests.run()
await StoreTests.run()
exit(Runner.summary())
