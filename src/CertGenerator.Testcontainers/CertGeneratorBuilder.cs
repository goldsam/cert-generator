using Docker.DotNet.Models;
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Configurations;
using DotNet.Testcontainers.Volumes;

namespace CertGenerator.Testcontainers;

public sealed class CertGeneratorBuilder : ContainerBuilder<CertGeneratorBuilder, CertGeneratorContainer, ContainerConfiguration>
{
    public const string CertGeneratorImage = "ghcr.io/goldsam/cert-generator:latest";

    public const string ConfigPath = "/config.yml";

    public const string CertsPath = "/certs";

    protected override ContainerConfiguration DockerResourceConfiguration { get; }

    /// <summary>
    /// Initializes a new instance of the <see cref="AzuriteBuilder" /> class.
    /// </summary>
    public CertGeneratorBuilder()
        : this(new ContainerConfiguration())
    {
        DockerResourceConfiguration = Init().DockerResourceConfiguration;
    }

    /// <summary>
    /// Initializes a new instance of the <see cref="AzuriteBuilder" /> class.
    /// </summary>
    /// <param name="resourceConfiguration">The Docker resource configuration.</param>
    private CertGeneratorBuilder(ContainerConfiguration resourceConfiguration)
        : base(resourceConfiguration)
    {
        DockerResourceConfiguration = resourceConfiguration;
    }

    /// <summary>
    /// Bind a host directory to capture the generated certificates.
    /// </summary>
    public CertGeneratorBuilder WithHostCertificates(string hostPath)
    {
        return WithBindMount(hostPath, ConfigPath);
    }

    /// <summary>
    /// Bind a volume to capture the generated certificates.
    /// </summary>
    public CertGeneratorBuilder WithVolumeCertificates(IVolume volume)
    {
        return WithVolumeMount(volume, CertsPath);
    }

    /// <summary>
    /// Bind a volume to capture the generated certificates.
    /// </summary>
    /// <param name="name">Name of the managed volume.</param>
    public CertGeneratorBuilder WithVolumeCertificates(string name)
    {
        return WithVolumeMount(name, CertsPath);
    }

    /// <summary>
    /// Bind a configuration file (config.yml) from the host into the container.
    /// </summary>
    public CertGeneratorBuilder WithHostConfiguration(string hostConfigPath)
    {
        return WithBindMount(hostConfigPath, ConfigPath);
    }

    /// <inheritdoc />
    public override CertGeneratorContainer Build()
    {
        Validate();

        var waitStrategy = Wait.ForUnixContainer().UntilMessageIsLogged("Certificates were succesully updated.");
        var builder = WithWaitStrategy(waitStrategy).WithCommand(ConfigPath);

        return new CertGeneratorContainer(builder.DockerResourceConfiguration);
    }

    /// <inheritdoc />
    protected override CertGeneratorBuilder Init()
    {
        return base.Init()
            .WithImage(CertGeneratorImage);
    }

    /// <inheritdoc />
    protected override CertGeneratorBuilder Clone(IResourceConfiguration<CreateContainerParameters> resourceConfiguration)
    {
        return Merge(DockerResourceConfiguration, new ContainerConfiguration(resourceConfiguration));
    }

    /// <inheritdoc />
    protected override CertGeneratorBuilder Clone(IContainerConfiguration resourceConfiguration)
    {
        return Merge(DockerResourceConfiguration, new ContainerConfiguration(resourceConfiguration));
    }

    /// <inheritdoc />
    protected override CertGeneratorBuilder Merge(ContainerConfiguration oldValue, ContainerConfiguration newValue)
    {
        return new CertGeneratorBuilder(new ContainerConfiguration(oldValue, newValue));
    }
}