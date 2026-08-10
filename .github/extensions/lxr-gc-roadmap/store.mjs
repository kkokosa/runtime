import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const extensionDirectory = dirname(fileURLToPath(import.meta.url));
const roadmapPath = join(extensionDirectory, "roadmap.md");
const benchmarkResultsDirectory = join(extensionDirectory, "benchmark-results");
const statuses = new Set(["planned", "in_progress", "done", "failed"]);
let mutationQueue = Promise.resolve();

function serializeMutation(operation) {
    const result = mutationQueue.then(operation, operation);
    mutationQueue = result.then(
        () => undefined,
        () => undefined,
    );
    return result;
}

function parseField(body, name) {
    const match = body.match(new RegExp(`^- \\*\\*${name}:\\*\\*\\s*(.*)$`, "mi"));
    return match?.[1]?.trim() ?? "";
}

function parseRoadmap(markdown) {
    const phases = [];
    const phasePattern = /^## (P\d+) — (.+)$/gm;
    const phaseMatches = [...markdown.matchAll(phasePattern)];

    for (let index = 0; index < phaseMatches.length; index++) {
        const match = phaseMatches[index];
        const start = match.index + match[0].length;
        const end = phaseMatches[index + 1]?.index ?? markdown.length;
        const body = markdown.slice(start, end);
        const firstStep = body.search(/^### /m);
        const phaseBody = firstStep >= 0 ? body.slice(0, firstStep) : body;
        const steps = [];
        const stepPattern = /^### (P\d+\.\d+) — (.+)$/gm;
        const stepMatches = [...body.matchAll(stepPattern)];

        for (let stepIndex = 0; stepIndex < stepMatches.length; stepIndex++) {
            const stepMatch = stepMatches[stepIndex];
            const stepStart = stepMatch.index + stepMatch[0].length;
            const stepEnd = stepMatches[stepIndex + 1]?.index ?? body.length;
            const stepBody = body.slice(stepStart, stepEnd);
            steps.push({
                id: stepMatch[1],
                title: stepMatch[2].trim(),
                status: parseField(stepBody, "Status") || "planned",
                summary: parseField(stepBody, "Summary"),
                correctness: parseField(stepBody, "Correctness"),
                benchmarks: parseField(stepBody, "Benchmarks"),
                runtimeChanges: parseField(stepBody, "Runtime changes"),
                dependencies: parseField(stepBody, "Dependencies"),
                references: parseField(stepBody, "References"),
            });
        }

        phases.push({
            id: match[1],
            title: match[2].trim(),
            status: parseField(phaseBody, "Status") || "planned",
            summary: parseField(phaseBody, "Summary"),
            steps,
        });
    }

    return phases;
}

async function writeAtomic(path, content) {
    const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
    try {
        await writeFile(temporaryPath, content, "utf8");
        await rename(temporaryPath, path);
    } finally {
        await rm(temporaryPath, { force: true });
    }
}

function requireText(value, name) {
    if (typeof value !== "string" || value.trim().length === 0) {
        throw new Error(`${name} must be a non-empty string.`);
    }
    return value.trim();
}

function optionalMetric(value, name) {
    if (value === undefined || value === null) {
        return null;
    }
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        throw new Error(`${name} must be a finite, non-negative number.`);
    }
    return value;
}

export async function readRoadmap() {
    return readFile(roadmapPath, "utf8");
}

async function readBenchmarkDocuments() {
    await mkdir(benchmarkResultsDirectory, { recursive: true });
    const files = (await readdir(benchmarkResultsDirectory))
        .filter((file) => file.endsWith(".json"))
        .sort();
    return Promise.all(
        files.map(async (file) => ({
            file,
            document: JSON.parse(await readFile(join(benchmarkResultsDirectory, file), "utf8")),
        })),
    );
}

async function readBenchmarks() {
    const sources = await readBenchmarkDocuments();

    return {
        schemaVersion: 1,
        metrics: Object.assign({}, ...sources.map(({ document }) => document.metrics ?? {})),
        checkpoints: sources
            .flatMap(({ document }) => document.checkpoints ?? [document])
            .sort((left, right) => left.date.localeCompare(right.date)),
        sourceFiles: sources.map(({ file }) => file),
    };
}

export async function getState() {
    const [markdown, benchmarks] = await Promise.all([
        readRoadmap(),
        readBenchmarks(),
    ]);
    const phases = parseRoadmap(markdown);
    const steps = phases.flatMap((phase) => phase.steps);

    return {
        phases,
        benchmarks,
        markdown,
        roadmapRevision: createHash("sha256").update(markdown).digest("hex"),
        progress: {
            total: steps.length,
            planned: steps.filter((step) => step.status === "planned").length,
            inProgress: steps.filter((step) => step.status === "in_progress").length,
            done: steps.filter((step) => step.status === "done").length,
            failed: steps.filter((step) => step.status === "failed").length,
        },
    };
}

export async function updateStep(input) {
    return serializeMutation(async () => {
        const id = requireText(input?.id, "id");
        let markdown = await readRoadmap();
        const escapedId = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const heading = new RegExp(`(^### ${escapedId} — .+$)([\\s\\S]*?)(?=^### |^## |$(?![\\s\\S]))`, "m");
        const match = markdown.match(heading);
        if (!match) {
            throw new Error(`Unknown roadmap step: ${id}`);
        }

        let section = match[0];
        const updates = {
            Status: input.status,
            Summary: input.summary,
            Correctness: input.correctness,
            Benchmarks: input.benchmarks,
            "Runtime changes": input.runtimeChanges,
        };

        if (input.status !== undefined && !statuses.has(input.status)) {
            throw new Error("status must be planned, in_progress, done, or failed.");
        }

        for (const [field, value] of Object.entries(updates)) {
            if (value === undefined) {
                continue;
            }
            const normalized = String(value).replace(/\r?\n/g, " ").trim();
            const fieldPattern = new RegExp(`^- \\*\\*${field}:\\*\\*.*$`, "mi");
            if (!fieldPattern.test(section)) {
                if (field === "Runtime changes") {
                    section = section.replace(
                        /^- \*\*Dependencies:\*\*/mi,
                        () => `- **Runtime changes:** ${normalized}\n- **Dependencies:**`,
                    );
                    continue;
                }
                throw new Error(`Roadmap step ${id} has no ${field} field.`);
            }
            section = section.replace(fieldPattern, () => `- **${field}:** ${normalized}`);
        }

        markdown = markdown.replace(match[0], () => section);
        await writeAtomic(roadmapPath, markdown);
        return getState();
    });
}

export async function addBenchmarkResult(input) {
    return serializeMutation(async () => {
        const checkpoint = requireText(input?.checkpoint, "checkpoint");
        const date = requireText(input?.date, "date");
        const stepId = requireText(input?.stepId, "stepId");
        const scenario = requireText(input?.scenario, "scenario");
        const collector = requireText(input?.collector, "collector");

        if (!["lxr", "workstation", "server"].includes(collector)) {
            throw new Error("collector must be lxr, workstation, or server.");
        }
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
            throw new Error("date must use YYYY-MM-DD format.");
        }
        const phases = parseRoadmap(await readRoadmap());
        if (!phases.some((phase) => phase.steps.some((step) => step.id === stepId))) {
            throw new Error(`Unknown roadmap step: ${stepId}`);
        }

        const sources = await readBenchmarkDocuments();
        const source = sources.find(({ document }) =>
            (document.checkpoints ?? [document]).some((item) => item.id === checkpoint),
        );
        const existing = (source?.document.checkpoints ?? (source ? [source.document] : []))
            .find((item) => item.id === checkpoint);
        if (existing && (existing.date !== date || existing.stepId !== stepId)) {
            throw new Error(
                `Checkpoint ${checkpoint} already belongs to ${existing.stepId} on ${existing.date}.`,
            );
        }
        const entry = existing ?? { id: checkpoint, date, stepId, notes: "", results: [] };

        const result = {
            scenario,
            collector,
            operationsPerSecond: optionalMetric(input.operationsPerSecond, "operationsPerSecond"),
            pauseAverageMs: optionalMetric(input.pauseAverageMs, "pauseAverageMs"),
            pauseP99Ms: optionalMetric(input.pauseP99Ms, "pauseP99Ms"),
            pauseMaxMs: optionalMetric(input.pauseMaxMs, "pauseMaxMs"),
            workingSetMb: optionalMetric(input.workingSetMb, "workingSetMb"),
            committedMb: optionalMetric(input.committedMb, "committedMb"),
            notes: typeof input.notes === "string" ? input.notes.trim() : "",
        };
        const resultIndex = entry.results.findIndex(
            (item) => item.scenario === scenario && item.collector === collector,
        );
        if (resultIndex >= 0) {
            entry.results[resultIndex] = result;
        } else {
            entry.results.push(result);
        }

        const safeCheckpoint = checkpoint.replace(/[^A-Za-z0-9._-]+/g, "-");
        const document = source?.document ?? {
            schemaVersion: 1,
            checkpoints: [entry],
        };
        const destination = source?.file ?? `${safeCheckpoint}.json`;
        await writeAtomic(
            join(benchmarkResultsDirectory, destination),
            `${JSON.stringify(document, null, 4)}\n`,
        );
        return getState();
    });
}

export async function replaceRoadmap(markdown, expectedRevision) {
    return serializeMutation(async () => {
        if (typeof markdown !== "string" || !markdown.includes("<!-- lxr-gc-roadmap:v1 -->")) {
            throw new Error("Markdown must contain the lxr-gc-roadmap:v1 format marker.");
        }
        const currentMarkdown = await readRoadmap();
        const currentRevision = createHash("sha256").update(currentMarkdown).digest("hex");
        if (expectedRevision !== currentRevision) {
            throw new Error("The roadmap changed after the editor loaded. Refresh before saving.");
        }
        const phases = parseRoadmap(markdown);
        if (phases.length === 0 || phases.every((phase) => phase.steps.length === 0)) {
            throw new Error("Markdown must contain at least one phase and one step.");
        }
        const invalidStatus = phases
            .flatMap((phase) => [phase.status, ...phase.steps.map((step) => step.status)])
            .find((status) => !statuses.has(status));
        if (invalidStatus) {
            throw new Error(`Invalid roadmap status: ${invalidStatus}`);
        }
        await writeAtomic(roadmapPath, markdown.endsWith("\n") ? markdown : `${markdown}\n`);
        return getState();
    });
}
