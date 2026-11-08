// Appended to Machines.swift by the test, so private internals remain private
// in production. Seed tunnels without SSH or timers, then inspect the real list.
extension Machines {
    func fixture(_ data: Data) throws {
        let profiles = try JSONDecoder().decode([Profile].self, from: data)
        q.sync {
            env = HerdrCore.environment
            all = profiles
            var taken: [String: Profile] = [:]
            for profile in profiles where profile.enabled {
                let key = Self.key(profile, taken: taken)
                taken[key] = profile
                let tunnel = Tunnel(key: key, profile: profile)
                tunnel.lastUp = Date()
                tunnels[key] = tunnel
                for name in ["\(key).sock", "\(key)-client.sock"] {
                    try! Data().write(to: Self.dir.appendingPathComponent(name))
                }
            }
            writeList()
            publish()
        }
    }
    var fixtureKeys: [String] { q.sync { tunnels.keys.sorted() } }
}
