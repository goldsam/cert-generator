using DotNet.Testcontainers.Configurations;
using DotNet.Testcontainers.Containers;

namespace CertGenerator.Testcontainers;

public class CertGeneratorContainer : DockerContainer
{
    /// <summary>
    /// Initializes a new instance of the <see cref="AzuriteContainer" /> class.
    /// </summary>
    /// <param name="configuration">The container configuration.</param>
    public CertGeneratorContainer(ContainerConfiguration configuration)
        : base(configuration)
    {
    }
}
