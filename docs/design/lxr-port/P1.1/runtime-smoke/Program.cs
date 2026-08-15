// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

internal static class Program
{
    private static int Main()
    {
        Node root = new();
        for (int collection = 0; collection < 20; collection++)
        {
            Node current = root;
            for (int index = 0; index < 100_000; index++)
            {
                current.Next = new Node();
                current = current.Next;
            }

            GC.Collect();
            GC.WaitForPendingFinalizers();
            root.Next = null;
        }

        Console.WriteLine("PASS");
        return 0;
    }
}

internal sealed class Node
{
    public Node? Next;
}
