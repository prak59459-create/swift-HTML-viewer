struct Employee {
    let name: String
    let department: String
    var salary: Int
    var annual: Int { return salary * 12 }
}
var staff = [
    Employee(name: "ann", department: "eng", salary: 500),
    Employee(name: "bob", department: "sales", salary: 400),
    Employee(name: "cid", department: "eng", salary: 600),
]
staff.sort { $0.salary > $1.salary }
for person in staff { print(person.name, person.salary, person.annual) }
let engineers = staff.filter { $0.department == "eng" }
print(engineers.count, engineers.map { $0.name }.joined(separator: "+"))
let payroll = staff.reduce(0) { $0 + $1.salary }
print(payroll)
staff[0].salary += 50
print(staff[0].salary, staff[0].annual)
let names = staff.map { $0.name }.sorted()
print(names)
