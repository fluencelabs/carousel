const core = require("@actions/core");
const { Octokit } = require("@octokit/rest");
const fs = require("fs");

async function run() {
  try {
    const token = process.env.GITHUB_TOKEN;
    const octokit = new Octokit({ auth: token });

    // Load local versions.json file
    const file = JSON.parse(fs.readFileSync("versions.json", "utf8"));
    const cliVersion = file.cli.split("@")[2]; // Extract CLI version

    // Get the package.json content from the fluencelabs/cli repository
    const packageRes = await octokit.repos.getContent({
      owner: "fluencelabs",
      repo: "cli",
      path: "package.json",
      ref: `fluence-cli-v${cliVersion}`,
    });

    const packageContent = Buffer.from(packageRes.data.content, "base64")
      .toString();
    const packageJson = JSON.parse(packageContent);

    // Filter only the direct dependencies starting with '@fluencelabs'
    const filteredPackageJsonDependencies = {};
    for (const dep in packageJson.dependencies) {
      if (dep.startsWith("@fluencelabs")) {
        filteredPackageJsonDependencies[dep] = packageJson.dependencies[dep];
      }
    }

    // Get the src/versions.json content from the fluencelabs/cli repository
    const versionsRes = await octokit.repos.getContent({
      owner: "fluencelabs",
      repo: "cli",
      path: "src/versions.json",
      ref: `fluence-cli-v${cliVersion}`,
    });

    const versions = JSON.parse(
      Buffer.from(versionsRes.data.content, "base64").toString(),
    );

    // Merge dependencies from versions.json and package-lock.json
    const mergedNpmDependencies = {
      ...versions.npm,
      ...filteredPackageJsonDependencies,
    };
    versions.npm = mergedNpmDependencies;

    // Add 'nox' from local file
    versions.nox = file.nox;

    // Add 'faucet'
    versions.faucet = file.faucet;

    console.log(JSON.stringify(versions, null, 2));
    core.setOutput("versions", JSON.stringify(versions));

    // Add 'nox' output
    const regex = /:(?:[a-zA-Z_]+_)?(\d+\.\d+\.\d+)$/;
    const match = versions.nox.match(regex);
    if (match) {
      const noxVersion = match[1];
      console.log(`nox version is set to ${noxVersion}`);
      core.setOutput("nox", noxVersion);
    } else {
      core.setFailed("Couldn't get nox version.");
    }

    // Add 'cli' outputs
    core.setOutput("cli_tag", `fluence-cli-v${cliVersion}`);
    core.setOutput("cli_version", cliVersion);

    // Add npm packages as list for CI matrix
    const npmPackages = [];
    for (const [name, version] of Object.entries(versions.npm)) {
      npmPackages.push({ name, version: version.replace(/^\^/, "") });
    }
    core.setOutput("npm", JSON.stringify(npmPackages));
  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
