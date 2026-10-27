using System;

if (args.Length != 3 || (args[0] != "FirstWrite" && args[0] != "Repeated"))
{
    throw new ArgumentException("Expected FirstWrite|Repeated Copy|Clear|Fill|Overlap count.");
}
bool first = args[0] == "FirstWrite";
int count = int.Parse(args[2]);
RepeatedBulkStores stores = first ? new FirstWriteBulkStores() : new RepeatedBulkStores();
stores.Count = count;
stores.Setup();
for (int iteration = 0; iteration < 3; iteration++)
{
    if (first)
    {
        ((FirstWriteBulkStores)stores).PrepareIteration();
    }
    long result = args[1] switch
    {
        "Fill" => stores.Fill(),
        "Copy" => stores.Copy(),
        "Clear" => stores.Clear(),
        "Overlap" => stores.Overlap(),
        _ => throw new ArgumentException("Unknown bulk operation."),
    };
    if (result != (args[1] == "Clear" ? 0 : 73))
    {
        throw new InvalidOperationException("The selected operation returned incorrect data.");
    }
}
Console.WriteLine($"PASS codegen-only {args[0]} {args[1]} Count={count}; three operations, not a timing result.");
