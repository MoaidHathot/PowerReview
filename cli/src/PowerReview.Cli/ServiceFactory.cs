using PowerReview.Core.Auth;
using PowerReview.Core.Configuration;
using PowerReview.Core.Services;
using PowerReview.Core.Store;

namespace PowerReview.Cli;

/// <summary>
/// Creates and caches service instances for CLI command handlers.
/// </summary>
internal sealed class ServiceFactory
{
    private readonly Lazy<PowerReviewConfig> _config;
    private readonly Lazy<SessionStore> _store;
    private readonly Lazy<SessionService> _sessionService;
    private readonly Lazy<ReviewService> _reviewService;
    private readonly Lazy<FixWorktreeService> _fixWorktreeService;
    private readonly Lazy<ProposalService> _proposalService;

    internal ServiceFactory()
    {
        _config = new Lazy<PowerReviewConfig>(() => ConfigLoader.Load());
        _store = new Lazy<SessionStore>(() => new SessionStore(_config.Value));
        _sessionService = new Lazy<SessionService>(() => new SessionService(_store.Value));
        _reviewService = new Lazy<ReviewService>(() => new ReviewService(
            _store.Value,
            _sessionService.Value,
            _config.Value,
            new AuthResolver(_config.Value.Auth)));
        _fixWorktreeService = new Lazy<FixWorktreeService>(() => new FixWorktreeService(
            _store.Value,
            _config.Value));
        _proposalService = new Lazy<ProposalService>(() => new ProposalService(
            _store.Value,
            _sessionService.Value,
            _fixWorktreeService.Value));
    }

    internal PowerReviewConfig Config => _config.Value;
    internal SessionStore Store => _store.Value;
    internal SessionService SessionService => _sessionService.Value;
    internal ReviewService ReviewService => _reviewService.Value;
    internal FixWorktreeService FixWorktreeService => _fixWorktreeService.Value;
    internal ProposalService ProposalService => _proposalService.Value;
}
