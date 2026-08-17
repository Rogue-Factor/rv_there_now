const inputPath = scriptArgs[1];
const outputPath = scriptArgs[2];
if (!inputPath || !outputPath) {
    std.exit(2);
}

let playlist;
try {
    playlist = JSON.parse(std.loadFile(inputPath));
} catch (_) {
    std.exit(3);
}

if (!Array.isArray(playlist)) {
    std.exit(4);
}

const output = std.open(outputPath, "w");
if (!output) {
    std.exit(5);
}

let count = 0;
for (const item of playlist) {
    if (!item || item.track_artist === "runspot") {
        continue;
    }
    if (typeof item.primary !== "string" || typeof item.fn !== "string") {
        continue;
    }
    const url = `${item.primary}${item.fn}.m4a`;
    if (!url.startsWith("https://") || /[\r\n\t]/.test(url)) {
        continue;
    }
    output.puts(`${url}\n`);
    count++;
}
output.close();
std.exit(count > 0 ? 0 : 6);
