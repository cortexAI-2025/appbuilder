import { Octokit } from "octokit";

export interface GithubSettings {
  token: string;
  owner: string;
  repo: string;
}

export const validateRepository = async (settings: GithubSettings) => {
  const octokit = new Octokit({ auth: settings.token });
  try {
    const { data } = await octokit.rest.repos.get({
      owner: settings.owner,
      repo: settings.repo,
    });
    return { success: true, data };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};

export const uploadProjectZip = async (settings: GithubSettings, file: File) => {
  const octokit = new Octokit({ auth: settings.token });

  // Convert File to base64 (Browser compatible)
  const content = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.readAsDataURL(file);
    reader.onload = () => {
      const base64 = (reader.result as string).split(',')[1];
      resolve(base64);
    };
    reader.onerror = (error) => reject(error);
  });

  try {
    // Check if file exists to get sha
    let sha: string | undefined;
    try {
      const { data: fileData } = await octokit.rest.repos.getContent({
        owner: settings.owner,
        repo: settings.repo,
        path: 'project.zip',
      });
      if (!Array.isArray(fileData) && 'sha' in fileData) {
        sha = fileData.sha;
      }
    } catch {
      // File doesn't exist, which is fine
    }

    await octokit.rest.repos.createOrUpdateFileContents({
      owner: settings.owner,
      repo: settings.repo,
      path: 'project.zip',
      message: 'Upload project.zip for build',
      content,
      sha,
    });
    return { success: true };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};

export const triggerWorkflow = async (settings: GithubSettings, buildType: 'apk' | 'aab') => {
  const octokit = new Octokit({ auth: settings.token });
  try {
    await octokit.rest.actions.createWorkflowDispatch({
      owner: settings.owner,
      repo: settings.repo,
      workflow_id: 'build-android.yml',
      ref: 'main', // Assuming main branch, could be improved
      inputs: {
        build_type: buildType,
      },
    });
    return { success: true };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};

export const getLatestWorkflowRun = async (settings: GithubSettings) => {
  const octokit = new Octokit({ auth: settings.token });
  try {
    const { data } = await octokit.rest.actions.listWorkflowRuns({
      owner: settings.owner,
      repo: settings.repo,
      workflow_id: 'build-android.yml',
      per_page: 1,
    });
    return { success: true, run: data.workflow_runs[0] };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};

export const getArtifacts = async (settings: GithubSettings, runId: number) => {
  const octokit = new Octokit({ auth: settings.token });
  try {
    const { data } = await octokit.rest.actions.listWorkflowRunArtifacts({
      owner: settings.owner,
      repo: settings.repo,
      run_id: runId,
    });
    return { success: true, artifacts: data.artifacts };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};

export const getArtifactDownloadUrl = async (settings: GithubSettings, artifactId: number) => {
  const octokit = new Octokit({ auth: settings.token });
  try {
    const { data } = await octokit.rest.actions.downloadArtifact({
      owner: settings.owner,
      repo: settings.repo,
      artifact_id: artifactId,
      archive_format: 'zip',
    });
    // downloadArtifact returns a redirect to the actual zip
    return { success: true, url: (data as any).url };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};
