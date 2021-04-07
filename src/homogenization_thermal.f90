!--------------------------------------------------------------------------------------------------
!> @author Martin Diehl, KU Leuven
!--------------------------------------------------------------------------------------------------
submodule(homogenization) thermal

  use lattice

  interface

    module subroutine pass_init
    end subroutine pass_init

    module subroutine isotemperature_init
    end subroutine isotemperature_init

  end interface

  type :: tDataContainer
    real(pReal), dimension(:), allocatable :: T, dot_T
  end type tDataContainer

  type(tDataContainer), dimension(:), allocatable :: current

  type :: tParameters
    character(len=pStringLen), allocatable, dimension(:) :: &
      output
  end type tParameters

  type(tparameters),             dimension(:), allocatable :: &
    param


contains

!--------------------------------------------------------------------------------------------------
!> @brief Allocate variables and set parameters.
!--------------------------------------------------------------------------------------------------
module subroutine thermal_init()

  class(tNode), pointer :: &
    configHomogenizations, &
    configHomogenization, &
    configHomogenizationThermal
  integer :: ho


  print'(/,a)', ' <<<+-  homogenization:thermal init  -+>>>'
  print'(/,a)', ' <<<+-  homogenization:thermal:isotemperature init  -+>>>'



  configHomogenizations => config_material%get('homogenization')
  allocate(param(configHomogenizations%length))
  allocate(current(configHomogenizations%length))

  do ho = 1, configHomogenizations%length
    allocate(current(ho)%T(count(material_homogenizationID==ho)), source=300.0_pReal)
    allocate(current(ho)%dot_T(count(material_homogenizationID==ho)), source=0.0_pReal)
    configHomogenization => configHomogenizations%get(ho)
    associate(prm => param(ho))
      if (configHomogenization%contains('thermal')) then
        configHomogenizationThermal => configHomogenization%get('thermal')
#if defined (__GFORTRAN__)
        prm%output = output_as1dString(configHomogenizationThermal)
#else
        prm%output = configHomogenizationThermal%get_as1dString('output',defaultVal=emptyStringArray)
#endif
      else
        prm%output = emptyStringArray
      endif
    end associate
  enddo

end subroutine thermal_init


!--------------------------------------------------------------------------------------------------
!> @brief Partition temperature onto the individual constituents.
!--------------------------------------------------------------------------------------------------
module subroutine thermal_partition(ce)

  integer,     intent(in) :: ce

  real(pReal) :: T, dot_T
  integer :: co


  T     = current(material_homogenizationID(ce))%T(material_homogenizationEntry(ce))
  dot_T = current(material_homogenizationID(ce))%dot_T(material_homogenizationEntry(ce))
  do co = 1, homogenization_Nconstituents(material_homogenizationID(ce))
    call phase_thermal_setField(T,dot_T,co,ce)
  enddo

end subroutine thermal_partition


!--------------------------------------------------------------------------------------------------
!> @brief Homogenize temperature rates
!--------------------------------------------------------------------------------------------------
module subroutine thermal_homogenize(ip,el)

  integer, intent(in) :: ip,el

  !call phase_thermal_getRate(homogenization_dot_T((el-1)*discretization_nIPs+ip), ip,el)

end subroutine thermal_homogenize


!--------------------------------------------------------------------------------------------------
!> @brief return homogenized thermal conductivity in reference configuration
!--------------------------------------------------------------------------------------------------
module function thermal_conduction_getConductivity(ce) result(K)

  integer, intent(in) :: ce
  real(pReal), dimension(3,3) :: K

  integer :: &
    co

  K = 0.0_pReal

  do co = 1, homogenization_Nconstituents(material_homogenizationID(ce))
    K = K + crystallite_push33ToRef(co,ce,lattice_K(:,:,material_phaseID(co,ce)))
  enddo

  K = K / real(homogenization_Nconstituents(material_homogenizationID(ce)),pReal)

end function thermal_conduction_getConductivity


module function homogenization_thermal_mu_T(ce) result(mu_T)
  
  integer, intent(in) :: ce
  real(pReal) :: mu_T

  mu_T = c_P(ce) * rho(ce)

end function homogenization_thermal_mu_T


!--------------------------------------------------------------------------------------------------
!> @brief returns homogenized specific heat capacity
!--------------------------------------------------------------------------------------------------
function c_P(ce)

  integer, intent(in) :: ce
  real(pReal) :: c_P

  integer :: co


  c_P = lattice_c_p(material_phaseID(1,ce))
  do co = 2, homogenization_Nconstituents(material_homogenizationID(ce))
    c_P = c_P + lattice_c_p(material_phaseID(co,ce))
  enddo

  c_P = c_P / real(homogenization_Nconstituents(material_homogenizationID(ce)),pReal)

end function c_P


!--------------------------------------------------------------------------------------------------
!> @brief returns homogenized mass density
!--------------------------------------------------------------------------------------------------
function rho(ce)

  integer, intent(in) :: ce
  real(pReal) :: rho

  integer :: co


  rho = lattice_rho(material_phaseID(1,ce))
  do co = 2, homogenization_Nconstituents(material_homogenizationID(ce))
    rho = rho + lattice_rho(material_phaseID(co,ce))
  enddo

  rho = rho / real(homogenization_Nconstituents(material_homogenizationID(ce)),pReal)

end function rho



!--------------------------------------------------------------------------------------------------
!> @brief Set thermal field and its rate (T and dot_T)
!--------------------------------------------------------------------------------------------------
module subroutine homogenization_thermal_setField(T,dot_T, ce)

  integer, intent(in) :: ce
  real(pReal),   intent(in) :: T, dot_T


  current(material_homogenizationID(ce))%T(material_homogenizationEntry(ce)) = T
  current(material_homogenizationID(ce))%dot_T(material_homogenizationEntry(ce)) = dot_T


end subroutine homogenization_thermal_setField



!--------------------------------------------------------------------------------------------------
!> @brief writes results to HDF5 output file
!--------------------------------------------------------------------------------------------------
module subroutine thermal_results(ho,group)

  integer,          intent(in) :: ho
  character(len=*), intent(in) :: group

  integer :: o

  associate(prm => param(ho))
    outputsLoop: do o = 1,size(prm%output)
      select case(trim(prm%output(o)))
        case('T')
          call results_writeDataset(group,current(ho)%T,'T','temperature','K')
      end select
    enddo outputsLoop
  end associate

end subroutine thermal_results


module function homogenization_thermal_T(ce) result(T)

  integer, intent(in) :: ce
  real(pReal) :: T

  T = current(material_homogenizationID(ce))%T(material_homogenizationEntry(ce))

end function homogenization_thermal_T



!--------------------------------------------------------------------------------------------------
!> @brief return heat generation rate
!--------------------------------------------------------------------------------------------------
module subroutine thermal_conduction_getSource(Tdot, ip, el)

  integer, intent(in) :: &
    ip, &
    el
  real(pReal), intent(out) :: &
    Tdot

  integer :: co, ho,ph,me
  real(pReal) :: dot_T_temp

  ho = material_homogenizationAt(el)
  Tdot = 0.0_pReal
  do co = 1, homogenization_Nconstituents(ho)
     ph = material_phaseAt(co,el)
     me = material_phasememberAt(co,ip,el)
     call phase_thermal_getRate(dot_T_temp, ph,me)
     Tdot = Tdot + dot_T_temp
  enddo

  Tdot = Tdot/real(homogenization_Nconstituents(ho),pReal)

end subroutine thermal_conduction_getSource


end submodule thermal
