using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using PowerReview.Core.Models;

namespace PowerReview.Core.Providers.AzureDevOps;

/// <summary>
/// Azure DevOps REST API provider for pull request operations.
/// </summary>
public sealed class AzDoProvider : IProvider
{
    private readonly HttpClient _http;
    private readonly string _org;
    private readonly string _project;
    private readonly string _repo;
    private readonly string _baseUrl;
    private readonly string _apiVersion;

    public ProviderType ProviderType => ProviderType.AzDo;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public AzDoProvider(string org, string project, string repo, string authHeader, string apiVersion = "7.1")
    {
        _org = org;
        _project = project;
        _repo = repo;
        _apiVersion = apiVersion;

        var encodedOrg = Uri.EscapeDataString(org);
        var encodedProject = Uri.EscapeDataString(project);
        var encodedRepo = Uri.EscapeDataString(repo);
        _baseUrl = $"https://dev.azure.com/{encodedOrg}/{encodedProject}/_apis/git/repositories/{encodedRepo}";

        _http = new HttpClient();
        _http.DefaultRequestHeaders.Authorization = AuthenticationHeaderValue.Parse(authHeader);
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    private string BuildUrl(string path, Dictionary<string, string>? queryParams = null)
    {
        var url = $"{_baseUrl}{path}";
        var separator = url.Contains('?') ? "&" : "?";
        url += $"{separator}api-version={_apiVersion}";

        if (queryParams != null)
        {
            foreach (var (key, value) in queryParams)
            {
                url += $"&{Uri.EscapeDataString(key)}={Uri.EscapeDataString(value)}";
            }
        }

        return url;
    }

    private async Task<T> GetAsync<T>(string path, Dictionary<string, string>? queryParams = null, CancellationToken ct = default)
    {
        var url = BuildUrl(path, queryParams);
        var response = await _http.GetAsync(url, ct);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct))!;
    }

    private async Task<T> PostAsync<T>(string path, object body, CancellationToken ct = default)
    {
        var url = BuildUrl(path);
        var content = new StringContent(JsonSerializer.Serialize(body, JsonOptions), Encoding.UTF8, "application/json");
        var response = await _http.PostAsync(url, content, ct);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct))!;
    }

    private async Task<T> PatchAsync<T>(string path, object body, CancellationToken ct = default)
    {
        var url = BuildUrl(path);
        var content = new StringContent(JsonSerializer.Serialize(body, JsonOptions), Encoding.UTF8, "application/json");
        var response = await _http.PatchAsync(url, content, ct);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct))!;
    }

    private async Task<T> PutAsync<T>(string path, object body, CancellationToken ct = default)
    {
        var url = BuildUrl(path);
        var content = new StringContent(JsonSerializer.Serialize(body, JsonOptions), Encoding.UTF8, "application/json");
        var response = await _http.PutAsync(url, content, ct);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct))!;
    }

    private async Task DeleteRequestAsync(string path, CancellationToken ct = default)
    {
        var url = BuildUrl(path);
        var response = await _http.DeleteAsync(url, ct);
        response.EnsureSuccessStatusCode();
    }

    // =========================================================================
    // Get Pull Request
    // =========================================================================

    public async Task<PullRequest> GetPullRequestAsync(int prId, CancellationToken ct = default)
    {
        var data = await GetAsync<AzDoApiModels.PullRequestResponse>($"/pullrequests/{prId}", ct: ct);
        return MapPullRequest(data);
    }

    private static PullRequest MapPullRequest(AzDoApiModels.PullRequestResponse data)
    {
        return new PullRequest
        {
            Id = data.PullRequestId,
            Title = data.Title ?? "",
            Description = data.Description ?? "",
            Author = new PersonIdentity
            {
                Name = data.CreatedBy?.DisplayName ?? "Unknown",
                Id = data.CreatedBy?.Id,
                UniqueName = data.CreatedBy?.UniqueName,
            },
            SourceBranch = StripRefsHeads(data.SourceRefName ?? ""),
            TargetBranch = StripRefsHeads(data.TargetRefName ?? ""),
            Status = ParsePrStatus(data.Status),
            Url = data.Url ?? "",
            CreatedAt = data.CreationDate ?? "",
            ClosedAt = data.ClosedDate,
            IsDraft = data.IsDraft,
            MergeStatus = ParseMergeStatus(data.MergeStatus),
            Reviewers = data.Reviewers?.Select(r => new Reviewer
            {
                Name = r.DisplayName ?? "",
                Id = r.Id,
                UniqueName = r.UniqueName,
                Vote = r.Vote == 0 ? null : r.Vote,
                IsRequired = r.IsRequired,
            }).ToList() ?? [],
            Labels = data.Labels?.Select(l => l.Name ?? "").Where(n => !string.IsNullOrEmpty(n)).ToList() ?? [],
            WorkItems = [], // Work items require separate API call; not included in PR response
            ProviderType = ProviderType.AzDo,
        };
    }

    // =========================================================================
    // Get Changed Files
    // =========================================================================

    public async Task<(List<ChangedFile> Files, IterationMeta Iteration)> GetChangedFilesAsync(int prId, CancellationToken ct = default)
    {
        // Step 1: Get iterations to find the latest
        var iterations = await GetAsync<AzDoApiModels.ListResponse<AzDoApiModels.IterationResponse>>(
            $"/pullrequests/{prId}/iterations", ct: ct);

        if (iterations.Value == null || iterations.Value.Count == 0)
            return ([], new IterationMeta());

        var lastIteration = iterations.Value[^1];
        var iterMeta = new IterationMeta
        {
            Id = lastIteration.Id,
            SourceCommit = lastIteration.SourceRefCommit?.CommitId,
            TargetCommit = lastIteration.TargetRefCommit?.CommitId,
        };

        // Step 2: Get changes for the last iteration
        var changes = await GetAsync<AzDoApiModels.IterationChangesResponse>(
            $"/pullrequests/{prId}/iterations/{lastIteration.Id}/changes", ct: ct);

        var files = new List<ChangedFile>();
        if (changes.ChangeEntries != null)
        {
            foreach (var entry in changes.ChangeEntries)
            {
                // Skip folders
                if (entry.Item?.GitObjectType == "tree")
                    continue;

                var path = StripLeadingSlash(entry.Item?.Path ?? "");
                var originalPath = StripLeadingSlash(entry.Item?.OriginalPath ?? entry.OriginalPath ?? "");

                files.Add(new ChangedFile
                {
                    Path = path,
                    ChangeType = MapChangeType(entry.ChangeType),
                    OriginalPath = string.IsNullOrEmpty(originalPath) ? null : originalPath,
                });
            }
        }

        return (files, iterMeta);
    }

    // =========================================================================
    // Get Threads
    // =========================================================================

    public async Task<List<CommentThread>> GetThreadsAsync(int prId, CancellationToken ct = default)
    {
        var data = await GetAsync<AzDoApiModels.ListResponse<AzDoApiModels.ThreadResponse>>(
            $"/pullrequests/{prId}/threads", ct: ct);

        var threads = new List<CommentThread>();
        if (data.Value != null)
        {
            foreach (var raw in data.Value)
            {
                if (IsSystemThread(raw))
                    continue;

                threads.Add(MapThread(raw));
            }
        }

        return threads;
    }

    private static bool IsSystemThread(AzDoApiModels.ThreadResponse thread)
    {
        if (thread.Comments == null || thread.Comments.Count == 0)
            return true;

        var firstComment = thread.Comments[0];
        return firstComment.CommentType is "system" or "2";
    }

    private static CommentThread MapThread(AzDoApiModels.ThreadResponse raw)
    {
        var thread = new CommentThread
        {
            Id = raw.Id,
            Status = ParseThreadStatus(raw.Status),
            IsDeleted = raw.IsDeleted,
            PublishedAt = raw.PublishedDate,
            UpdatedAt = raw.LastUpdatedDate,
        };

        // Thread context (file location)
        if (raw.ThreadContext != null)
        {
            thread.FilePath = StripLeadingSlash(raw.ThreadContext.FilePath ?? "");

            if (raw.ThreadContext.RightFileStart != null)
            {
                thread.LineStart = raw.ThreadContext.RightFileStart.Line;
                thread.ColStart = raw.ThreadContext.RightFileStart.Offset > 1
                    ? raw.ThreadContext.RightFileStart.Offset : null;
            }
            if (raw.ThreadContext.RightFileEnd != null)
            {
                thread.LineEnd = raw.ThreadContext.RightFileEnd.Line;
                thread.ColEnd = raw.ThreadContext.RightFileEnd.Offset > 1
                    ? raw.ThreadContext.RightFileEnd.Offset : null;
            }
            if (raw.ThreadContext.LeftFileStart != null)
                thread.LeftLineStart = raw.ThreadContext.LeftFileStart.Line;
            if (raw.ThreadContext.LeftFileEnd != null)
                thread.LeftLineEnd = raw.ThreadContext.LeftFileEnd.Line;
        }

        // Comments
        if (raw.Comments != null)
        {
            thread.Comments = raw.Comments.Select(c => new Comment
            {
                Id = c.Id,
                ThreadId = raw.Id,
                Author = new PersonIdentity
                {
                    Name = c.Author?.DisplayName ?? "",
                    Id = c.Author?.Id,
                    UniqueName = c.Author?.UniqueName,
                },
                ParentCommentId = c.ParentCommentId == 0 ? null : c.ParentCommentId,
                Body = c.Content ?? "",
                CreatedAt = c.PublishedDate ?? "",
                UpdatedAt = c.LastUpdatedDate ?? "",
                IsDeleted = c.IsDeleted,
            }).ToList();
        }

        return thread;
    }

    // =========================================================================
    // Create Thread
    // =========================================================================

    public async Task<CommentThread> CreateThreadAsync(int prId, CreateThreadRequest request, CancellationToken ct = default)
    {
        var body = new Dictionary<string, object>
        {
            ["comments"] = new[] { new { parentCommentId = 0, content = request.Body, commentType = 1 } },
            ["status"] = ThreadStatusToApi(request.Status),
        };

        if (!string.IsNullOrEmpty(request.FilePath))
        {
            var filePath = request.FilePath.StartsWith('/') ? request.FilePath : $"/{request.FilePath}";
            if (request.LineStart.HasValue)
            {
                body["threadContext"] = new
                {
                    filePath,
                    rightFileStart = new { line = request.LineStart.Value, offset = request.ColStart ?? 1 },
                    rightFileEnd = new { line = request.LineEnd ?? request.LineStart.Value, offset = request.ColEnd ?? 1 },
                };
            }
            else
            {
                // File-level comment: attach to the file but no specific line position
                body["threadContext"] = new { filePath };
            }
        }

        var response = await PostAsync<AzDoApiModels.ThreadResponse>($"/pullrequests/{prId}/threads", body, ct);
        return MapThread(response);
    }

    // =========================================================================
    // Reply to Thread
    // =========================================================================

    public async Task<Comment> ReplyToThreadAsync(int prId, int threadId, string body, CancellationToken ct = default)
    {
        var requestBody = new { content = body, commentType = 1 };
        var response = await PostAsync<AzDoApiModels.CommentResponse>(
            $"/pullrequests/{prId}/threads/{threadId}/comments", requestBody, ct);

        return new Comment
        {
            Id = response.Id,
            ThreadId = threadId,
            Author = new PersonIdentity
            {
                Name = response.Author?.DisplayName ?? "",
                Id = response.Author?.Id,
                UniqueName = response.Author?.UniqueName,
            },
            ParentCommentId = response.ParentCommentId == 0 ? null : response.ParentCommentId,
            Body = response.Content ?? "",
            CreatedAt = response.PublishedDate ?? "",
            UpdatedAt = response.LastUpdatedDate ?? "",
            IsDeleted = response.IsDeleted,
        };
    }

    // =========================================================================
    // Update Comment
    // =========================================================================

    public async Task<Comment> UpdateCommentAsync(int prId, int threadId, int commentId, string body, CancellationToken ct = default)
    {
        var requestBody = new { content = body };
        var response = await PatchAsync<AzDoApiModels.CommentResponse>(
            $"/pullrequests/{prId}/threads/{threadId}/comments/{commentId}", requestBody, ct);

        return new Comment
        {
            Id = response.Id,
            ThreadId = threadId,
            Author = new PersonIdentity
            {
                Name = response.Author?.DisplayName ?? "",
                Id = response.Author?.Id,
                UniqueName = response.Author?.UniqueName,
            },
            Body = response.Content ?? "",
            CreatedAt = response.PublishedDate ?? "",
            UpdatedAt = response.LastUpdatedDate ?? "",
            IsDeleted = response.IsDeleted,
        };
    }

    // =========================================================================
    // Delete Comment
    // =========================================================================

    public async Task DeleteCommentAsync(int prId, int threadId, int commentId, CancellationToken ct = default)
    {
        await DeleteRequestAsync($"/pullrequests/{prId}/threads/{threadId}/comments/{commentId}", ct);
    }

    // =========================================================================
    // Set Vote
    // =========================================================================

    public async Task SetVoteAsync(int prId, string reviewerId, int vote, CancellationToken ct = default)
    {
        var body = new { vote };
        await PutAsync<object>($"/pullrequests/{prId}/reviewers/{Uri.EscapeDataString(reviewerId)}", body, ct);
    }

    // =========================================================================
    // Get File Content
    // =========================================================================

    public async Task<string> GetFileContentAsync(string filePath, string branch, CancellationToken ct = default)
    {
        var path = filePath.StartsWith('/') ? filePath : $"/{filePath}";
        var url = BuildUrl("/items", new Dictionary<string, string>
        {
            ["path"] = path,
            ["versionDescriptor.version"] = branch,
            ["versionDescriptor.versionType"] = "branch",
            ["$format"] = "text",
        });

        var response = await _http.GetAsync(url, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync(ct);
    }

    // =========================================================================
    // Get Current Reviewer ID
    // =========================================================================

    public async Task<string> GetCurrentReviewerIdAsync(CancellationToken ct = default)
    {
        // This endpoint is at the org level, not the repo level
        var url = $"https://dev.azure.com/{Uri.EscapeDataString(_org)}/_apis/connectionData?api-version={_apiVersion}";
        var response = await _http.GetAsync(url, ct);
        response.EnsureSuccessStatusCode();

        var data = await response.Content.ReadFromJsonAsync<AzDoApiModels.ConnectionDataResponse>(JsonOptions, ct);
        return data?.AuthenticatedUser?.Id
            ?? throw new InvalidOperationException("Could not determine current reviewer ID from connection data.");
    }

    // =========================================================================
    // Update Thread Status
    // =========================================================================

    public async Task<CommentThread> UpdateThreadStatusAsync(int prId, int threadId, ThreadStatus status, CancellationToken ct = default)
    {
        var body = new Dictionary<string, object>
        {
            ["status"] = ThreadStatusToApi(status),
        };

        var response = await PatchAsync<AzDoApiModels.ThreadResponse>(
            $"/pullrequests/{prId}/threads/{threadId}", body, ct);
        return MapThread(response);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private static string StripRefsHeads(string refName)
    {
        const string prefix = "refs/heads/";
        return refName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? refName[prefix.Length..]
            : refName;
    }

    private static string StripLeadingSlash(string path)
    {
        return path.StartsWith('/') ? path[1..] : path;
    }

    private static PullRequestStatus ParsePrStatus(string? status) => status?.ToLowerInvariant() switch
    {
        "completed" => PullRequestStatus.Completed,
        "abandoned" => PullRequestStatus.Abandoned,
        _ => PullRequestStatus.Active,
    };

    private static MergeStatus? ParseMergeStatus(string? status) => status?.ToLowerInvariant() switch
    {
        "succeeded" => MergeStatus.Succeeded,
        "conflicts" => MergeStatus.Conflicts,
        "queued" => MergeStatus.Queued,
        "notset" => MergeStatus.NotSet,
        "failure" => MergeStatus.Failure,
        _ => null,
    };

    private static ThreadStatus ParseThreadStatus(object? status)
    {
        var s = status?.ToString()?.ToLowerInvariant();
        return s switch
        {
            "1" or "active" => ThreadStatus.Active,
            "2" or "fixed" => ThreadStatus.Fixed,
            "3" or "wontfix" => ThreadStatus.WontFix,
            "4" or "closed" => ThreadStatus.Closed,
            "5" or "bydesign" => ThreadStatus.ByDesign,
            "6" or "pending" => ThreadStatus.Pending,
            _ => ThreadStatus.Active,
        };
    }

    private static int ThreadStatusToApi(ThreadStatus status) => status switch
    {
        ThreadStatus.Active => 1,
        ThreadStatus.Fixed => 2,
        ThreadStatus.WontFix => 3,
        ThreadStatus.Closed => 4,
        ThreadStatus.ByDesign => 5,
        ThreadStatus.Pending => 6,
        _ => 1,
    };

    private static ChangeType MapChangeType(object? changeType)
    {
        var s = changeType?.ToString()?.ToLowerInvariant();
        return s switch
        {
            "add" or "1" => ChangeType.Add,
            "edit" or "2" => ChangeType.Edit,
            "delete" or "16" => ChangeType.Delete,
            "rename" or "8" => ChangeType.Rename,
            _ => ChangeType.Edit,
        };
    }
}
