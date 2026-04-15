"use client";

import { useEffect, useState, useCallback } from "react";
import { GithubSettings, getLatestWorkflowRun, getArtifacts } from "@/lib/github";
import { Loader2, Download, CheckCircle, XCircle, Clock, ExternalLink } from "lucide-react";

interface Props {
  settings: GithubSettings;
  isBuilding: boolean;
  onBuildComplete: () => void;
}

export default function BuildStatus({ settings, isBuilding, onBuildComplete }: Props) {
  const [run, setRun] = useState<any>(null);
  const [artifacts, setArtifacts] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [startTime] = useState(new Date());

  const fetchArtifacts = useCallback(async (runId: number) => {
    setLoading(true);
    const result = await getArtifacts(settings, runId);
    if (result.success && result.artifacts) {
      setArtifacts(result.artifacts);
    }
    setLoading(false);
  }, [settings]);

  useEffect(() => {
    let interval: NodeJS.Timeout;

    if (isBuilding || (run && (run.status === "queued" || run.status === "in_progress"))) {
      const fetchStatus = async () => {
        const result = await getLatestWorkflowRun(settings);
        if (result.success && result.run) {
          // Check if this run was created after we started the build
          const runCreatedAt = new Date(result.run.created_at);
          if (runCreatedAt >= startTime) {
            setRun(result.run);
            if (result.run.status === "completed") {
              onBuildComplete();
              fetchArtifacts(result.run.id);
            }
          }
        }
      };

      fetchStatus();
      interval = setInterval(fetchStatus, 10000); // Poll every 10 seconds
    }

    return () => clearInterval(interval);
  }, [isBuilding, run, settings, onBuildComplete, fetchArtifacts, startTime]);

  const getStatusIcon = (status: string, conclusion: string) => {
    if (status !== "completed") return <Clock className="w-5 h-5 text-blue-500 animate-pulse" />;
    return conclusion === "success" ? (
      <CheckCircle className="w-5 h-5 text-green-500" />
    ) : (
      <XCircle className="w-5 h-5 text-red-500" />
    );
  };

  const getStatusText = (status: string, conclusion: string) => {
    if (status === "queued") return "En attente...";
    if (status === "in_progress") return "Compilation en cours...";
    if (status === "completed") return conclusion === "success" ? "Réussi" : "Échoué";
    return status;
  };

  if (!run && !isBuilding) return null;

  return (
    <div className="bg-white dark:bg-gray-800 p-6 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 space-y-4">
      <h2 className="text-xl font-semibold mb-2">Statut de la compilation</h2>

      {run ? (
        <div className="space-y-4">
          <div className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-900 rounded-lg">
            <div className="flex items-center gap-3">
              {getStatusIcon(run.status, run.conclusion)}
              <div>
                <p className="font-medium">{getStatusText(run.status, run.conclusion)}</p>
                <p className="text-xs text-gray-500">Démarré le {new Date(run.created_at).toLocaleString()}</p>
              </div>
            </div>
            <a
              href={run.html_url}
              target="_blank"
              rel="noopener noreferrer"
              className="text-blue-500 hover:text-blue-600 transition-colors"
            >
              <ExternalLink className="w-5 h-5" />
            </a>
          </div>

          {run.status === "completed" && run.conclusion === "success" && (
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Artifacts générés :</h3>
              {loading ? (
                <div className="flex items-center gap-2 text-sm text-gray-500">
                  <Loader2 className="w-4 h-4 animate-spin" /> Chargement des liens...
                </div>
              ) : artifacts.length > 0 ? (
                <div className="grid grid-cols-1 gap-2">
                  {artifacts.map((artifact) => (
                    <a
                      key={artifact.id}
                      href={`https://github.com/${settings.owner}/${settings.repo}/suites/${run.check_suite_id}/artifacts/${artifact.id}`}
                      className="flex items-center justify-between p-3 border rounded-lg hover:bg-gray-50 dark:hover:bg-gray-900 transition-colors group"
                    >
                      <div className="flex items-center gap-2">
                        <Download className="w-4 h-4 text-blue-500" />
                        <span className="text-sm font-medium">{artifact.name}</span>
                      </div>
                      <span className="text-xs text-gray-500 group-hover:text-blue-500">Télécharger (ZIP)</span>
                    </a>
                  ))}
                  <p className="text-[10px] text-gray-400 mt-1 italic">
                    Note: Les liens d&apos;artifacts GitHub nécessitent d&apos;être connecté à votre compte GitHub.
                  </p>
                </div>
              ) : (
                <p className="text-sm text-gray-500">Aucun artifact trouvé.</p>
              )}
            </div>
          )}

          {run.status === "completed" && run.conclusion === "failure" && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-400 rounded-lg text-sm">
              La compilation a échoué. Veuillez vérifier les logs sur GitHub pour plus de détails.
            </div>
          )}
        </div>
      ) : (
        <div className="flex items-center gap-3 p-3">
          <Loader2 className="w-5 h-5 animate-spin text-blue-500" />
          <p className="text-sm">Initialisation du workflow...</p>
        </div>
      )}
    </div>
  );
}
